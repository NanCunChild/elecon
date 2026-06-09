/**
 * 公网哑服务（public）—— 无状态、零凭证。
 *
 * 红线（AGENTS.md #1/#2）：本服务永远不得持有或持久化任何凭证 / 私密数据。
 * 它只做两件事：分发 adapter、缓存公开（非私密）数据。
 *
 * adapter 在服务端用 QuickJS-wasm 执行（见 ../runtime/sandbox.ts），
 * 与客户端是同一个引擎，零语义漂移（ADR-005）。
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";

const PORT = Number(process.env.PORT ?? 8080);

function handler(req: IncomingMessage, res: ServerResponse): void {
  const url = req.url ?? "/";

  if (url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok" }));
    return;
  }

  if (url.startsWith("/adapters/")) {
    // TODO: 静态分发已签名 adapter 包（仅公开数据，零凭证）。
    res.writeHead(501, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "not_implemented", detail: "adapter distribution" }));
    return;
  }

  res.writeHead(404, { "content-type": "application/json" });
  res.end(JSON.stringify({ status: "not_found" }));
}

const server = createServer(handler);
server.listen(PORT, () => {
  console.log(`elecon public server (dumb, stateless, zero-credential) listening on :${PORT}`);
});
