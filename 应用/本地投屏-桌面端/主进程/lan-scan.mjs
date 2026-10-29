import os from "node:os";
import net from "node:net";
import { lanGetJson } from "./lan-http.mjs";

export const PHONE_PORT = 11019;

function isPrivateIPv4(ip) {
  if (!net.isIPv4(ip) || ip === "0.0.0.0" || ip.startsWith("127.")) return false;
  const p = ip.split(".").map(Number);
  if (p[0] === 10) return true;
  if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
  if (p[0] === 192 && p[1] === 168) return true;
  return false;
}

function prefixFromNetmask(address, netmask) {
  if (!netmask || !net.isIPv4(netmask)) return 24;
  const parts = netmask.split(".").map(Number);
  let bits = 0;
  for (const p of parts) {
    let v = p;
    for (let i = 0; i < 8; i++) {
      if (v & 0x80) bits++;
      else return bits;
      v <<= 1;
    }
  }
  return bits || 24;
}

function ipToInt(ip) {
  return ip.split(".").reduce((a, b) => (a << 8) + Number(b), 0) >>> 0;
}

function intToIp(n) {
  return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join(".");
}

function hostsForPrefix(address, prefix) {
  const ip = ipToInt(address);
  const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
  const network = (ip & mask) >>> 0;
  const broadcast = (network | (~mask >>> 0)) >>> 0;
  const first = network + 1;
  const last = broadcast - 1;
  const list = [];
  for (let n = first; n <= last; n++) list.push(intToIp(n));
  return { network: intToIp(network), prefix, first: intToIp(first), last: intToIp(last), list };
}

/** 枚举可扫描网卡与主机列表（可按 interfaceAddress 限定） */
export function listScanTargets(phonePort = PHONE_PORT, { interfaceAddress = "" } = {}) {
  const ifaces = os.networkInterfaces();
  const segments = [];
  const seen = new Set();
  const selfIps = new Set();

  for (const entries of Object.values(ifaces)) {
    for (const e of entries || []) {
      if (e.family !== "IPv4" && e.family !== 4) continue;
      if (e.internal) continue;
      if (!isPrivateIPv4(e.address)) continue;
      selfIps.add(e.address);
      const prefix = prefixFromNetmask(e.address, e.netmask);
      const hosts = hostsForPrefix(e.address, Math.max(prefix, 24));
      const key = `${hosts.network}/${hosts.prefix}`;
      if (seen.has(key)) continue;
      seen.add(key);
      segments.push({
        address: e.address,
        cidr: `${hosts.network}/${hosts.prefix}`,
        label: `${e.address} · ${hosts.network}/${hosts.prefix}`,
        range: `${hosts.first}–${hosts.last}`,
        hosts: hosts.list,
        port: phonePort,
        segmentCount: 1,
        currentSegment: 0,
      });
    }
  }

  const preferred = interfaceAddress
    ? segments.filter((s) => s.address === interfaceAddress)
    : segments;
  const active = preferred.length ? preferred : segments;

  const allHosts = [];
  const hostSeen = new Set();
  for (const seg of active) {
    for (const ip of seg.hosts) {
      if (selfIps.has(ip) || hostSeen.has(ip)) continue;
      hostSeen.add(ip);
      allHosts.push(ip);
    }
  }

  return {
    phonePort,
    interfaces: segments.map(({ address, cidr, label, range, segmentCount, currentSegment }) => ({
      address,
      cidr,
      label,
      range,
      segmentCount,
      currentSegment,
    })),
    hosts: allHosts,
    total: allHosts.length,
    range: active[0]?.range || "",
    subnet: active[0]?.cidr || "",
    segments: {
      count: 1,
      index: 0,
      range: active[0]?.range || "",
    },
  };
}

async function probeQuick(ip, port, timeoutMs = 1500) {
  try {
    const { info } = await lanGetJson(ip, port, "/api/info", { timeoutMs });
    if (info?.protocol && info.protocol !== "lan-phonebase") return null;
    if (info?.licenseRequired === true) return null;
    return {
      ip,
      port,
      name: info?.name || ip,
      deviceId: info?.deviceId || "",
      info,
    };
  } catch {
    return null;
  }
}

export function scanStatusIdle(phonePort = PHONE_PORT) {
  const plan = listScanTargets(phonePort);
  return {
    running: false,
    devices: [],
    scanned: 0,
    total: 0,
    progress: 0,
    range: "",
    subnet: plan.subnet || "",
    segments: plan.segments,
    interfaces: plan.interfaces,
  };
}

/**
 * 并发扫描局域网；onProgress 推送中间状态。
 */
export async function scanLan({
  phonePort = PHONE_PORT,
  concurrency = 48,
  timeoutMs = 1200,
  interfaceAddress = "",
  onProgress,
  signal,
} = {}) {
  const plan = listScanTargets(phonePort, { interfaceAddress });
  const devices = [];
  let scanned = 0;
  let index = 0;
  const hosts = plan.hosts;
  let cancelled = false;

  const snapshot = (running) => ({
    running,
    cancelled,
    devices: devices.map(({ ip, port, name, deviceId }) => ({ ip, port, name, deviceId })),
    scanned,
    total: plan.total,
    progress: plan.total ? Math.min(100, Math.round((scanned / plan.total) * 100)) : running ? 0 : 100,
    range: plan.range,
    subnet: plan.subnet,
    segments: plan.segments,
    interfaces: plan.interfaces,
  });

  onProgress?.(snapshot(true));

  if (!hosts.length) {
    const done = snapshot(false);
    onProgress?.(done);
    return done;
  }

  const onAbort = () => {
    cancelled = true;
  };
  signal?.addEventListener("abort", onAbort, { once: true });

  const workers = Array.from({ length: Math.min(concurrency, hosts.length) }, async () => {
    while (true) {
      if (signal?.aborted) return;
      const i = index++;
      if (i >= hosts.length) return;
      const ip = hosts[i];
      const hit = await probeQuick(ip, phonePort, timeoutMs);
      scanned++;
      if (hit) devices.push(hit);
      if (scanned % 12 === 0 || hit || scanned === hosts.length) {
        onProgress?.(snapshot(true));
      }
    }
  });

  await Promise.all(workers);
  signal?.removeEventListener("abort", onAbort);
  const done = snapshot(false);
  onProgress?.(done);
  return done;
}
