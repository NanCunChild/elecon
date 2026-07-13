/**
 * 校内授权中继（campus）—— 部署在校内堡垒机后，代取私密数据。
 *
 * 🔒🔒 最高敏感承重路径（经手凭证，红线 #1/#3）。按 AGENTS.md §1 不得 AI 独自闭环。
 *
 * ⛔ **本模块被 ADR 阻塞，当前有意不实现 relay 取数**：
 *    ADR-012 §2.6 决策——**首版仅 client-direct**；campus-relay 的凭证落点方案**推迟**至
 *    ADR-003（传输底座）被接受并进入实现时再定。**在 relay 方案定案前，fetch-via-relay 不落地。**
 *    因此本文件只声明 relay 必须满足的**硬不变量与接口骨架**，不提供可用的代取实现——
 *    以免在 ADR-003 缺席下擅自定型凭证传输（会违反红线 #1/#6）。
 *
 * relay 任何未来实现都必须满足的硬约束（ADR-012 §2.6，先声明为编译期可见的契约）：
 *  1. **客户端始终是权威存储**；relay 执行时**零落盘**——不持久化任何凭证/私密数据。
 *  2. 凭证在 relay 侧**单次用完即弃**，或**注入仍在客户端完成**（relay 仅代理字节）——二选一。
 *  3. relay 不得成为凭证蜜罐：公网侧零凭证（红线 #2），私密数据只走校内授权环境（红线 #3）。
 *  4. 供应链最严：锁 lockfile、最小依赖、定期 npm audit（ADR-005 §3.3）。
 */

import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT ?? 8090);

// ---- relay 接口骨架（供 ADR-003 定案后人工实现；此处仅类型契约） ----

/** relay 代取请求（客户端 → campus）。凭证**不在此结构内**——见不变量 2（客户端注入或单次投递）。 */
export interface RelayRequest {
  /** 授权令牌：证明该客户端有权使用校内中继（非学生凭证；校内授权体系颁发）。 */
  authorizationToken: string;
  /** 目标（须落在中继允许的校内域白名单内）。 */
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

/** relay 代取结果（campus → 客户端）。仅代理字节，不解释、不落库。 */
export interface RelayResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

/**
 * relay 取数——🔒 **未实现（ADR-blocked）**。
 * 待 ADR-003 定案后由维护者人工实现，且实现必须通过上述四条硬不变量的安全清单审。
 */
export async function relayFetch(_req: RelayRequest): Promise<RelayResponse> {
  throw new Error(
    "⛔ campus relayFetch 被 ADR 阻塞：首版仅 client-direct，relay 落点待 ADR-003 定案（ADR-012 §2.6）。",
  );
}

function handler(req: IncomingMessage, res: ServerResponse): void {
  const url = req.url ?? "/";
  res.writeHead(url === "/health" ? 200 : 501, { "content-type": "application/json" });
  res.end(
    JSON.stringify(
      url === "/health"
        ? { status: "ok", relay: "blocked_on_adr_003", zeroDrop: true }
        : {
            status: "not_implemented",
            detail: "campus relay 被 ADR-012 §2.6 阻塞（首版仅 client-direct；relay 待 ADR-003）",
          },
    ),
  );
}

export { handler };

const invokedDirectly = process.argv[1] !== undefined && process.argv[1] === fileURLToPath(import.meta.url);
if (invokedDirectly) {
  const server = createServer(handler);
  server.listen(PORT, () => {
    console.log("elecon campus relay: ADR-blocked (ADR-012 §2.6, first version client-direct only).");
    console.log("Must be deployed inside the campus network, behind the bastion host.");
    console.log(`Health endpoint listening on :${PORT}`);
  });
}
