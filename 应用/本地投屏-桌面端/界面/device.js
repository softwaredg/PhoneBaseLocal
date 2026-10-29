import { ControlClient, VideoSession, mapControlKey, normalizeControlText } from "./player.js";

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const ip = params.get("ip") || "";
const port = Number(params.get("port") || 11019);
const name = params.get("name") || ip;
const deviceId = params.get("deviceId") || "";
let presentation = params.get("mode") === "portrait" ? "portrait" : "landscape";

document.title = name ? `${name} · 设备投屏` : "设备投屏";
$("device-title").textContent = name || "设备投屏";
$("device-short-id").textContent = deviceId ? deviceId.slice(0, 8) : "—";
$("device-address").textContent = ip ? `${ip}:${port}` : "缺少地址";
$("detail-name").textContent = name || "—";
$("detail-id").textContent = deviceId || "—";
$("detail-address").textContent = ip ? `${ip}:${port}` : "—";
$("device-window").dataset.mode = presentation;

let rotation = 0;
let controlling = false;
let control = null;
let session = null;
let fpsTimer = null;
let lastFrames = 0;
let lastFitKey = "";

function setPresentation(mode) {
  presentation = mode === "portrait" ? "portrait" : "landscape";
  $("device-window").dataset.mode = presentation;
  session?.player?.setPresentation?.(presentation);
  layoutCanvas();
  lastFitKey = "";
  fitWindowToVideo();
}

/** 与官方 Ce() 一致：按容器与旋转角设置 canvas CSS，避免旋转后留黑边 */
function layoutCanvas() {
  const screen = $("screen");
  const canvas = $("device-canvas");
  if (!screen || !canvas) return;
  const swap = Math.abs(rotation) % 180 === 90;
  const w = swap ? screen.clientHeight : screen.clientWidth;
  const h = swap ? screen.clientWidth : screen.clientHeight;
  canvas.style.width = `${Math.max(1, w)}px`;
  canvas.style.height = `${Math.max(1, h)}px`;
  canvas.style.transform = rotation
    ? `translate(-50%, -50%) rotate(${rotation}deg)`
    : "translate(-50%, -50%)";
  $("device-window").dataset.mode = presentation;
}

/** 按画面比例调整窗口内容区，消除 object-fit:contain 上下/左右黑边 */
function fitWindowToVideo() {
  const canvas = $("device-canvas");
  if (!canvas?.width || !canvas?.height) return;
  const key = `${canvas.width}x${canvas.height}:${rotation}`;
  if (key === lastFitKey) return;
  lastFitKey = key;
  window.desktopLocal?.fitDeviceContent?.({
    videoWidth: canvas.width,
    videoHeight: canvas.height,
    rotation,
  });
}

function setScreen(title, status) {
  $("screen-title").textContent = title;
  $("screen-status").textContent = status;
}

function showPlaceholder(show) {
  $("screen-placeholder").hidden = !show;
}

function setRtt(ms) {
  $("network-rtt").textContent = ms != null ? `接口 RTT ${ms} ms` : "接口 RTT —";
  $("detail-network").textContent = ms != null ? `${ms} ms` : "—";
}

function applyRotation(deg) {
  rotation = deg;
  $("rotation-device-menu").querySelector(".rotation-menu-status").textContent = `当前 ${deg}°`;
  layoutCanvas();
  lastFitKey = "";
  fitWindowToVideo();
}

/** 官方独立设备窗口默认全分辨率 /video（不用墙模式 maxDimension） */
function getProfile() {
  return { profile: "foreground" };
}

async function start() {
  if (!ip || !window.desktopLocal?.probeInfo) {
    setScreen("无法连接", "缺少 IP 或 preload");
    return;
  }
  setScreen("正在连接设备", "读取 /api/info…");
  let body;
  let rtt = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const t0 = performance.now();
    body = await window.desktopLocal.probeInfo(ip, port);
    rtt = Math.round(performance.now() - t0);
    setRtt(rtt);
    if (body.ok) break;
    setScreen("正在连接设备", `第 ${attempt}/3 次失败：${body.error || "探测失败"}`);
    await new Promise((r) => setTimeout(r, 400));
  }
  if (!body?.ok) {
    setScreen(
      "连接失败",
      `${body?.error || "探测失败"}\n请确认手机显示 build=0.1.6-thread-http，并彻底滑掉旧进程后重开`
    );
    return;
  }
  const info = body.info || {};
  const shownName = info.name || name || "设备投屏";
  document.title = `${shownName} · 设备投屏`;
  $("device-title").textContent = shownName;
  $("device-short-id").textContent = (info.deviceId || deviceId || "—").slice(0, 8);
  $("detail-name").textContent = shownName;
  $("detail-id").textContent = info.deviceId || deviceId || "—";
  $("device-address").textContent = `${body.ip}:${body.port}`;
  $("detail-address").textContent = `${body.ip}:${body.port}`;
  const baseWs = `ws://${body.ip}:${body.port}`;

  const canvas = $("device-canvas");
  session = new VideoSession({
    canvas,
    getProfile,
    presentation,
    onFrameTs: (ts) => control?.setFrameTs(ts),
    onFirstFrame: () => {
      showPlaceholder(false);
      $("capture-device").disabled = false;
      setScreen("已连接", "画面就绪 · 可直接控制");
      $("detail-resolution").textContent = `${canvas.width}×${canvas.height}`;
      layoutCanvas();
      fitWindowToVideo();
    },
    onSize: (w, h) => {
      $("detail-resolution").textContent = `${w}×${h}`;
      layoutCanvas();
      fitWindowToVideo();
    },
    onStatus: (t) => {
      $("screen-status").textContent = t;
      $("stream-notice").hidden = false;
      $("stream-notice").textContent = t;
    },
    onError: (e) => {
      $("stream-notice").hidden = false;
      $("stream-notice").textContent = e;
    },
  });

  fpsTimer = setInterval(() => {
    if (!session) return;
    const n = session.player.frames;
    $("detail-fps").textContent = `${Math.max(0, n - lastFrames)} fps`;
    lastFrames = n;
    if (canvas.width && canvas.height) $("detail-resolution").textContent = `${canvas.width}×${canvas.height}`;
    $("settings-profile").textContent = "foreground · 全分辨率";
  }, 1000);

  try {
    await session.open(baseWs);
  } catch (e) {
    setScreen("画面失败", e.message || String(e));
    return;
  }

  // 默认直接开启控制，无需开关
  try {
    control = new ControlClient({
      url: `${baseWs}/control`,
      onReady: (msg) => {
        $("detail-status").textContent = "控制中";
        updateTextCapability(msg);
      },
      onError: (e) => {
        $("detail-status").textContent = String(e);
      },
    });
    await control.connect();
    controlling = true;
    canvas.classList.add("touch-control");
    $("home-device").disabled = false;
    bindPointer(canvas);
    bindKeyboard(canvas);
    focusKeyCapture();
  } catch (e) {
    $("detail-status").textContent = e.message || String(e);
    setScreen("画面已连接", `控制未就绪: ${e.message || e}`);
  }
}

let inputArmed = false;
let composing = false;
let noticeTimer = null;

function setTextStatus(text, isError = false) {
  const el = $("device-text-status");
  if (el) {
    el.textContent = text || "";
    el.classList.toggle("error", !!isError && !!text);
  }
  // 画面上始终可见，避免面板收起时“没任何提示”
  showInputNotice(text, isError);
}

function showInputNotice(text, isError = false) {
  const notice = $("stream-notice");
  if (!notice || !text) return;
  notice.hidden = false;
  notice.textContent = text;
  notice.classList.toggle("error", !!isError);
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => {
    if (notice.textContent === text) notice.hidden = true;
  }, isError ? 5000 : 1600);
}

function updateTextCapability(msg) {
  const textOk = control?.textAvailable === true;
  const keyOk = control?.keyboardAvailable === true;
  // 能力位仅作提示：实际输入一律强制下发 text/key
  const detail = textOk || keyOk
    ? `键盘可用 · 点画面后直接打字`
    : `基座声明 textAvailable=false，仍将尝试发送；若手机无字请换支持键盘的官方本地基座 IPA`;
  setTextStatus(detail, !textOk && !keyOk);
  $("device-text-send").disabled = false;
  $("device-text-input").disabled = false;
  $("detail-status").textContent = `控制中 · text=${textOk ? "开" : "关"} key=${keyOk ? "开" : "关"}`;
}

function keyCapture() {
  return $("device-key-capture");
}

function focusKeyCapture() {
  const capture = keyCapture();
  if (!capture || !controlling || !control?.ready) return;
  inputArmed = true;
  try {
    capture.focus({ preventScroll: true });
  } catch {
    $("device-canvas")?.focus({ preventScroll: true });
  }
}

function bindPointer(canvas) {
  const norm = (ev) => {
    const rect = canvas.getBoundingClientRect();
    return {
      x: Math.min(1, Math.max(0, (ev.clientX - rect.left) / rect.width)),
      y: Math.min(1, Math.max(0, (ev.clientY - rect.top) / rect.height)),
    };
  };
  let pid = null;
  canvas.onpointerdown = (ev) => {
    if (!controlling || !control?.ready) return;
    if (ev.button === 0) focusKeyCapture();
    canvas.setPointerCapture(ev.pointerId);
    pid = ev.pointerId;
    const { x, y } = norm(ev);
    control.pointer("down", x, y);
  };
  canvas.onpointermove = (ev) => {
    if (pid !== ev.pointerId) return;
    const { x, y } = norm(ev);
    control.pointer("move", x, y);
  };
  const up = (ev) => {
    if (pid !== ev.pointerId) return;
    const { x, y } = norm(ev);
    control.pointer("up", x, y);
    pid = null;
    // 松手后夺回键盘焦点，避免被 canvas capture 抢走
    focusKeyCapture();
  };
  canvas.onpointerup = up;
  canvas.onpointercancel = up;
}

async function sendControlText(raw, { clearInput = false } = {}) {
  if (!control?.ready) {
    setTextStatus("控制未就绪", true);
    return false;
  }
  try {
    const text = normalizeControlText(raw);
    // 能力位 false 时仍强制发送：官方基座若误报，仍可能注入成功
    const forced = !control.canText;
    await control.text(text, { force: true });
    setTextStatus(
      forced
        ? `已强制发送「${text.length > 12 ? `${text.slice(0, 12)}…` : text}」（基座声明 textAvailable=false）`
        : `已发送「${text.length > 12 ? `${text.slice(0, 12)}…` : text}」`
    );
    if (clearInput) $("device-text-input").value = "";
    const capture = keyCapture();
    if (capture) capture.value = "";
    $("toggle-text-input").dataset.unsent = "false";
    return true;
  } catch (e) {
    setTextStatus(e.message || String(e), true);
    $("toggle-text-input").dataset.unsent = "true";
    return false;
  }
}

async function sendControlKey(name) {
  if (!control?.ready) {
    setTextStatus("控制未就绪", true);
    return;
  }
  try {
    await control.key(name, { force: true });
    setTextStatus(
      control.canKey ? `已发送按键 ${name}` : `已强制发送按键 ${name}（基座声明 keyboardAvailable=false）`
    );
  } catch (e) {
    setTextStatus(e.message || String(e), true);
  }
}

function isTypingTarget(el) {
  if (!el || el === document.body) return false;
  if (el === $("device-text-input")) return true;
  if (el.closest?.("dialog,input,textarea,select,[contenteditable=true]")) {
    // 隐藏 capture 不算“普通输入框”
    if (el === keyCapture() || el.id === "device-key-capture") return false;
    return true;
  }
  return false;
}

function handleTypedKeyDown(e) {
  if (!controlling || !control?.ready || !inputArmed || composing || e.isComposing) return false;
  if (isTypingTarget(e.target)) return false;
  const mapped = mapControlKey(e.key);
  if (mapped) {
    e.preventDefault();
    sendControlKey(mapped);
    return true;
  }
  if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
    e.preventDefault();
    sendControlText(e.key);
    return true;
  }
  return false;
}

function bindKeyboard(canvas) {
  const capture = keyCapture();
  const targets = [canvas, capture].filter(Boolean);

  // 窗口级兜底：点过画面后即使焦点丢失也能打字（Electron 常见）
  window.addEventListener(
    "keydown",
    (e) => {
      handleTypedKeyDown(e);
    },
    true
  );

  for (const el of targets) {
    el.addEventListener("beforeinput", (e) => {
      if (!controlling || !control?.ready || !inputArmed || composing || e.isComposing) return;
      if (isTypingTarget(e.target)) return;
      if (e.inputType === "insertFromComposition") {
        e.preventDefault();
        return;
      }
      if (e.inputType === "insertText" && e.data) {
        e.preventDefault();
        sendControlText(e.data);
        return;
      }
      if (["insertParagraph", "insertLineBreak"].includes(e.inputType)) {
        e.preventDefault();
        sendControlKey("enter");
        return;
      }
      if (e.inputType === "deleteContentBackward") {
        e.preventDefault();
        sendControlKey("backspace");
      }
    });
    el.addEventListener("paste", (e) => {
      if (!controlling || !control?.ready || !inputArmed || composing) return;
      if (isTypingTarget(e.target)) return;
      const text = e.clipboardData?.getData("text/plain");
      e.preventDefault();
      if (text) sendControlText(text);
    });
    el.addEventListener("compositionstart", () => {
      composing = true;
    });
    el.addEventListener("compositionend", (e) => {
      composing = false;
      if (e.data) sendControlText(e.data);
      if (capture) capture.value = "";
    });
    el.addEventListener("input", () => {
      if (!composing && capture && el === capture) capture.value = "";
    });
  }

  document.addEventListener(
    "pointerdown",
    (e) => {
      if (!e.target?.closest?.("#screen, #device-canvas, #device-key-capture")) {
        if (!e.target?.closest?.("#device-keyboard-tools")) inputArmed = false;
      }
    },
    true
  );
}

$("win-min").onclick = () => window.desktopLocal?.windowMinimize?.();
$("win-max").onclick = () => window.desktopLocal?.toggleMaximize?.();
$("close-device").onclick = () => window.desktopLocal?.windowClose?.() ?? window.close();
$("home-device").onclick = () => control?.home();
$("maximize-device").onclick = () => window.desktopLocal?.toggleMaximize?.();
window.desktopLocal?.onDeviceSetMode?.((payload) => {
  if (payload?.mode) setPresentation(payload.mode);
});
$("capture-device").onclick = () => {
  const canvas = $("device-canvas");
  if (!canvas.width) return;
  const a = document.createElement("a");
  a.download = `phonebase-${Date.now()}.png`;
  a.href = canvas.toDataURL("image/png");
  a.click();
};

$("open-details").onclick = () => $("details-dialog").showModal();
$("open-settings").onclick = () => $("settings-dialog").showModal();
$("toggle-text-input").onclick = () => {
  const panel = $("device-keyboard-tools");
  const open = panel.hidden;
  panel.hidden = !open;
  $("toggle-text-input").setAttribute("aria-expanded", open ? "true" : "false");
  $("toggle-text-input").setAttribute("aria-pressed", open ? "true" : "false");
  if (open) {
    $("device-text-input").focus();
    updateTextCapability();
  }
};
$("device-text-send").onclick = () => {
  sendControlText($("device-text-input").value, { clearInput: true });
};
$("device-text-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    sendControlText($("device-text-input").value, { clearInput: true });
  }
});
for (const dlg of document.querySelectorAll("dialog")) {
  dlg.querySelector(".close-dialog")?.addEventListener("click", () => dlg.close());
}

$("rotate-device").onclick = (e) => {
  e.stopPropagation();
  const menu = $("rotation-device-menu");
  menu.hidden = !menu.hidden;
  $("rotate-device").setAttribute("aria-expanded", menu.hidden ? "false" : "true");
};
$("rotation-device-menu").onclick = (e) => {
  const item = e.target.closest("[data-rotation]");
  if (!item) return;
  const v = item.dataset.rotation;
  if (v === "reset") applyRotation(0);
  else if (v === "90") applyRotation(90);
  else if (v === "-90") applyRotation(-90);
  else if (v === "180") applyRotation(180);
  $("rotation-device-menu").hidden = true;
};

window.addEventListener("resize", () => layoutCanvas());
new ResizeObserver(() => layoutCanvas()).observe($("screen"));

window.addEventListener("beforeunload", () => {
  clearInterval(fpsTimer);
  control?.close();
  session?.close();
});

layoutCanvas();
start();
