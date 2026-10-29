import { app, BrowserWindow, ipcMain, screen } from "electron";
import path from "node:path";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { scanLan, scanStatusIdle, PHONE_PORT } from "./lan-scan.mjs";
import { lanGetJson } from "./lan-http.mjs";

// 避免 Clash/系统代理把局域网请求拐走
for (const k of ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy"]) {
  if (process.env[k]) delete process.env[k];
}
process.env.NO_PROXY = "*";
process.env.no_proxy = "*";

const DEVICE_HEADER_H = 36;
const DEVICE_TOOLS_W = 40;

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const deviceWindows = new Map();
let scanAbort = null;

function isLanIPv4(ip) {
  if (!net.isIPv4(ip) || ip === "0.0.0.0") return false;
  const p = ip.split(".").map(Number);
  if (p[0] === 10) return true;
  if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
  if (p[0] === 192 && p[1] === 168) return true;
  if (p[0] === 127) return true;
  return false;
}

async function probeInfo(ip, port) {
  if (!isLanIPv4(ip)) {
    throw Object.assign(new Error("仅允许局域网 IPv4"), { code: "BAD_IP" });
  }
  const p = Number(port) || 11019;
  if (!Number.isInteger(p) || p < 1 || p > 65535) {
    throw Object.assign(new Error("端口无效"), { code: "BAD_PORT" });
  }

  try {
    const { info } = await lanGetJson(ip, p, "/api/info", { timeoutMs: 8000 });

    if (info.protocol && info.protocol !== "lan-phonebase") {
      throw Object.assign(new Error(`未知协议 ${info.protocol}`), { code: "BAD_PROTOCOL", info });
    }
    if (info.licenseRequired === true) {
      throw Object.assign(
        new Error(
          "当前手机是商业基座（licenseRequired=true）。本客户端仅支持非商业本地基座；请换 licenseRequired=false 的 IPA，或使用官方本地投屏。"
        ),
        { code: "LICENSE_REQUIRED", info }
      );
    }

    return { ip, port: p, info };
  } catch (e) {
    if (e?.code === "TIMEOUT" || e?.name === "AbortError") {
      throw Object.assign(new Error("探测超时：请确认手机与电脑同网且基座已启动"), { code: "TIMEOUT" });
    }
    throw e;
  }
}

function createMainWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 880,
    minHeight: 560,
    title: "手机投屏与控制",
    backgroundColor: "#eef0f4",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  win.removeMenu();
  win.loadFile(path.join(ROOT, "界面", "index.html"));
  return win;
}

function openDeviceWindow(device = {}) {
  const ip = String(device.ip || "");
  const port = Number(device.port) || 11019;
  const mode = device.mode === "portrait" ? "portrait" : "landscape";
  const key = `${ip}:${port}`;
  const existing = deviceWindows.get(key);
  if (existing && !existing.isDestroyed()) {
    // 已打开则按当前墙方向调整窗口比例
    if (mode === "landscape") existing.setSize(960, 580);
    else existing.setSize(420, 760);
    existing.webContents.send("device-set-mode", { mode });
    existing.focus();
    return existing;
  }

  const q = new URLSearchParams({
    ip,
    port: String(port),
    name: String(device.name || ip),
    deviceId: String(device.deviceId || ""),
    mode,
  });

  const win = new BrowserWindow({
    width: mode === "landscape" ? 960 : 420,
    height: mode === "landscape" ? 580 : 760,
    minWidth: mode === "landscape" ? 560 : 320,
    minHeight: mode === "landscape" ? 360 : 420,
    frame: false,
    title: device.name ? `${device.name} · 设备投屏` : "设备投屏",
    backgroundColor: "#ffffff",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  win.removeMenu();
  win.loadFile(path.join(ROOT, "界面", "device.html"), { search: `?${q.toString()}` });
  deviceWindows.set(key, win);
  win.on("closed", () => {
    if (deviceWindows.get(key) === win) deviceWindows.delete(key);
  });
  return win;
}

app.whenReady().then(() => {
  ipcMain.handle("probe-info", async (_event, { ip, port }) => {
    try {
      return { ok: true, ...(await probeInfo(String(ip || ""), port)) };
    } catch (e) {
      return {
        ok: false,
        error: e.message || String(e),
        code: e.code || "PROBE_FAILED",
        info: e.info || null,
      };
    }
  });

  ipcMain.handle("open-device-window", (_event, device) => {
    openDeviceWindow(device || {});
    return { ok: true };
  });

  ipcMain.handle("fit-device-content", (event, payload = {}) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win || win.isDestroyed() || win.isMaximized() || win.isFullScreen()) {
      return { ok: false };
    }
    let vw = Math.max(1, Math.round(Number(payload.videoWidth) || 0));
    let vh = Math.max(1, Math.round(Number(payload.videoHeight) || 0));
    if (!vw || !vh) return { ok: false };
    if (Math.abs(Number(payload.rotation) || 0) % 180 === 90) {
      const t = vw;
      vw = vh;
      vh = t;
    }
    const aspect = vw / vh;
    const [curW, curH] = win.getContentSize();
    const work = screen.getDisplayMatching(win.getBounds()).workAreaSize;
    const maxW = Math.max(480, work.width - 48);
    const maxH = Math.max(360, work.height - 48);
    let contentW;
    let contentH;
    if (aspect >= 1) {
      contentW = Math.min(maxW - DEVICE_TOOLS_W, Math.max(560, curW - DEVICE_TOOLS_W));
      contentH = Math.round(contentW / aspect);
      if (contentH + DEVICE_HEADER_H > maxH) {
        contentH = maxH - DEVICE_HEADER_H;
        contentW = Math.round(contentH * aspect);
      }
    } else {
      contentH = Math.min(maxH - DEVICE_HEADER_H, Math.max(520, curH - DEVICE_HEADER_H));
      contentW = Math.round(contentH * aspect);
      if (contentW + DEVICE_TOOLS_W > maxW) {
        contentW = maxW - DEVICE_TOOLS_W;
        contentH = Math.round(contentW / aspect);
      }
    }
    const nextW = Math.max(win.getMinimumSize()[0] || 320, contentW + DEVICE_TOOLS_W);
    const nextH = Math.max(win.getMinimumSize()[1] || 360, contentH + DEVICE_HEADER_H);
    if (Math.abs(nextW - curW) > 2 || Math.abs(nextH - curH) > 2) {
      win.setContentSize(nextW, nextH);
    }
    return { ok: true, width: nextW, height: nextH };
  });

  ipcMain.handle("toggle-maximize", (event) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win) return { ok: false };
    if (win.isMaximized()) win.unmaximize();
    else win.maximize();
    return { ok: true, maximized: win.isMaximized() };
  });

  ipcMain.handle("window-minimize", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.minimize();
    return { ok: true };
  });

  ipcMain.handle("window-close", (event) => {
    BrowserWindow.fromWebContents(event.sender)?.close();
    return { ok: true };
  });

  ipcMain.handle("scan-lan-status", () => ({ ok: true, ...scanStatusIdle(PHONE_PORT) }));

  ipcMain.handle("scan-lan", async (event, opts = {}) => {
    if (scanAbort) {
      try {
        scanAbort.abort();
      } catch {}
    }
    const ac = new AbortController();
    scanAbort = ac;
    try {
      const result = await scanLan({
        phonePort: Number(opts.port) || PHONE_PORT,
        interfaceAddress: String(opts.interfaceAddress || ""),
        signal: ac.signal,
        onProgress: (status) => {
          if (!event.sender.isDestroyed()) event.sender.send("scan-lan-progress", status);
        },
      });
      return { ok: true, ...result };
    } catch (e) {
      return { ok: false, error: e.message || String(e), devices: [], running: false };
    } finally {
      if (scanAbort === ac) scanAbort = null;
    }
  });

  ipcMain.handle("scan-lan-cancel", () => {
    if (scanAbort) {
      try {
        scanAbort.abort();
      } catch {}
      scanAbort = null;
    }
    return { ok: true, ...scanStatusIdle(PHONE_PORT) };
  });

  createMainWindow();

  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createMainWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
