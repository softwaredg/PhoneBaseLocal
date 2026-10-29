import http from "node:http";

/**
 * 直连局域网 HTTP（强制 IPv4，不走 HTTP_PROXY/系统代理）。
 * Electron/Node 的 fetch 会吃代理环境变量，导致手机已 accept 但桌面端仍「探测超时」。
 */
export function lanGetJson(ip, port, path = "/api/info", { timeoutMs = 8000, limit = 8192 } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: ip,
        port: Number(port) || 11019,
        path,
        method: "GET",
        family: 4,
        timeout: timeoutMs,
        headers: {
          Accept: "application/json",
          Connection: "close",
          "User-Agent": "PhoneBaseLocal-desktop",
        },
        // 明确不使用代理
        agent: false,
      },
      (res) => {
        const chunks = [];
        let size = 0;
        res.on("data", (c) => {
          size += c.length;
          if (size > limit) {
            req.destroy();
            reject(Object.assign(new Error("response too large"), { code: "TOO_LARGE" }));
            return;
          }
          chunks.push(c);
        });
        res.on("end", () => {
          const body = Buffer.concat(chunks).toString("utf8");
          if ((res.statusCode || 0) < 200 || (res.statusCode || 0) >= 300) {
            reject(
              Object.assign(new Error(`手机 ${path} HTTP ${res.statusCode}`), {
                code: "HTTP_ERROR",
                status: res.statusCode,
                body,
              })
            );
            return;
          }
          try {
            resolve({ status: res.statusCode, info: JSON.parse(body || "{}") });
          } catch (e) {
            reject(Object.assign(new Error("invalid json"), { code: "BAD_JSON", cause: e }));
          }
        });
      }
    );
    req.on("timeout", () => {
      req.destroy();
      reject(Object.assign(new Error("探测超时：请确认手机与电脑同网且基座已启动"), { code: "TIMEOUT" }));
    });
    req.on("error", (e) => {
      if (e?.code === "TIMEOUT") {
        reject(Object.assign(new Error("探测超时：请确认手机与电脑同网且基座已启动"), { code: "TIMEOUT" }));
        return;
      }
      reject(e);
    });
    req.end();
  });
}
