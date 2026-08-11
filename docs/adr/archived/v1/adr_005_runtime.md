# ADR-005：宿主语言与 adapter 执行沙箱

- **状态**：已接受（Accepted）
- **日期**：2026-06-08
- **依赖**：[`adr_000_abstract.md`](./adr_000_abstract.md)、[`adr_001_contract.md`](./adr_001_contract.md)
- **适用范围**：`server/`（公网哑服务 + 校内授权中继）的实现语言与 adapter 服务端执行栈；以及 `tools/` 工具链的实现语言。**显式覆盖** ADR-000 §5.2 中"服务端选 Go 而非 Node.js"一条，以及 ADR-000 §3.2 关于服务端用 `goja` / `quickjs-go` 的描述。

---

## 1. 背景（Context）

ADR-000 把"一份 adapter，两端运行"定为承重墙：客户端用 QuickJS，服务端原计划用 Go + `goja`（纯 Go 的 JS 引擎）。实践中暴露出两个问题：

1. **`goja` 的语法缺口是 Go 专属的税。** `goja` 不是完整的现代 JS 引擎，部分语法不支持，这意味着 adapter 作者被迫把语言基线钉死在 ES6 左右——既限制贡献者，又与"另一端的 QuickJS"产生**语义漂移**：同一份脚本两端行为可能不一致，而双跑一致性正是契约的 CI 闸门（ADR-001 §8）。
2. **当初"为性能上 Go"的理由对本负载偏弱。** 服务端职责是反代 + 缓存 + 发 adapter，是 **I/O 密集**型，而 I/O 并发正是 Node 事件循环的主场；Go 的 goroutine 优势主要体现在 CPU 密集场景。真有重解析，Node 用 `worker_threads` 卸载即可。

由此，原决策的代价（团队在不熟语言上更慢、引擎缺口）大于其收益。本文重新拍板。

**关键：把问题从"Go vs Node"重述为两个正交的问题——"宿主语言"与"adapter 执行沙箱"。** 这两件事此前被 Go 的"语言即引擎"耦合在一起，拆开后选型空间更干净。

---

## 2. 决策（Decision）

1. **宿主语言：TypeScript on Node.js。** `server/` 与 `tools/` 统一到 TS/Node。注意是 **TypeScript，不是裸 Node**。
2. **adapter 服务端沙箱：编译成 wasm 的 QuickJS（`quickjs-emscripten` 一类）。** 服务端与客户端同属 QuickJS/Bellard 谱系，但绑定、版本和编译配置不同；共享 golden/canary 控制已使用语义的漂移（事实修正见 ADR-008 §3.2）。
3. **全栈统一到 JS/TS：** adapter 是 JS、服务端是 TS、契约校验工具（`ajv` 一类）客户端服务端共用一套、`tools/` 也是 TS。一个心智模型，对"人力不足"的项目，统一语言的维护收益远大于逐组件抠性能——直接对齐 ADR-000 的低维护主线。

### 2.1 为什么是 QuickJS-wasm 而不是别的服务端执行方式

| 候选 | 取 | 舍 |
|---|---|---|
| **QuickJS-wasm（`quickjs-emscripten`，选用）** | 真正的沙箱；与客户端同属 QuickJS 谱系，可用共享 golden 约束已使用语义；全程纯 JS/wasm，无 cgo | 需管理 wasm 运行时与内存边界及跨绑定漂移 |
| Node 的 `vm` 模块 | 零依赖、就在标准库 | **`vm` 明确不是安全边界**，半可信/侧载 adapter 在里面等于裸奔——直接违背红线 #5 与信任分层 |
| Go + `goja` | 纯 Go、单二进制 | 引擎不完整、与客户端语义漂移（本文要解的问题） |
| Go + `quickjs-go` | 是 QuickJS、无语义漂移 | 需 cgo，抵消单静态二进制的部署优势 |
| `isolated-vm` | 强隔离的 V8 isolate | 去用前**必须先查其当前维护状态**；与客户端引擎不同（V8 vs QuickJS），有语义漂移风险 |

结论：**QuickJS-wasm 同时拿到真正的沙箱、与客户端接近的 QuickJS 语义基础、纯 JS/wasm 无 cgo**，比 Go+goja（有缺口）和 Go+quickjs-go（要 cgo）都干净；跨绑定一致性仍必须由共享 golden/canary 验证。

---

## 3. 三个配套前提（缺一不可）

这三条是本决策"不埋雷"的前提，**必须同时落地**，否则换 Node 反而得不偿失。

### 3.1 必须上 TypeScript，不是裸 Node

broker 边界、凭证处理、签名这些**承重路径**没有静态类型迟早出事。在本项目语境里，"Node"应一律读作"**TypeScript on Node**"。`server/` 与 `tools/` 都开 `strict` 模式。

### 3.2 adapter 绝不能用 Node 的 `vm` 模块跑

Node 的 `vm` 模块**不是安全边界**（官方文档明确声明）。半可信 / 侧载 adapter 在 `vm` 里能逃逸、能触达宿主能力，等于裸奔，直接打穿 ADR-000 的信任分层与红线 #5。

**唯一允许的服务端 adapter 执行方式是 QuickJS-wasm。** 这同时满足：

- **真正的沙箱**：wasm 线性内存内执行，无宿主引用泄漏；
- **可控语义漂移**：客户端与服务端分别对同一套 golden/canary 验证，承诺范围限于测试覆盖的已使用语义；
- **无 cgo**：纯 JS/wasm，不破坏 Node 的部署模型。

### 3.3 部署与供应链要补课

Go 白送的"单静态二进制"，Node 这边要主动补上：

- **打包**：用 Node 单可执行打包（SEA, Single Executable Application）或 Docker 提供等价的单产物分发。
- **供应链**：`node_modules` 的供应链风险对**校内那台经手凭证的服务器（`server/src/campus`）尤其要紧**——锁 `lockfile`、**最小依赖**、定期 `npm audit`。
- **风险分级**：公网那台（`server/src/public`）是无状态哑服务、零凭证，供应链风险低，可以宽松些；校内中继是承重路径，按最严标准对待。

---

## 4. 取舍（Consequences）

**收益**

- 消除 `goja` 语法缺口与两端语义漂移，"一份 adapter 两端运行"才真正成立。
- 全栈单一语言（JS/TS），契约校验（ajv）两端共用，贡献者与维护者心智统一，契合低维护主线。
- adapter 服务端沙箱是真正的安全边界，信任分层不被服务端实现削弱。

**代价 / 已知约束**

- 失去 Go 的单静态二进制部署——靠 SEA / Docker 补，运维多一步。
- `node_modules` 引入供应链面——靠 lockfile + 最小依赖 + audit 收敛，校内中继按承重路径对待。
- 团队需具备 TS 工程纪律（strict、边界类型）——这是把承重路径做稳的前提，不可省。
- QuickJS-wasm 的内存/超时边界需要在 `server/src/runtime/` 显式管理（执行超时、内存上限、无网络/无凭证默认）。

---

## 5. 落地清单（指向 `server/` 与 `tools/` 骨架）

- `server/`：TS/Node 工程（`package.json` + `tsconfig.json`，`strict`）。
  - `src/public/`：公网哑服务（无状态、零凭证）。
  - `src/campus/`：校内授权中继（承重路径，供应链按最严标准）。
  - `src/runtime/`：QuickJS-wasm（`quickjs-emscripten`）adapter 执行沙箱——超时、内存上限、无网络默认、与客户端同引擎。
- `tools/`：TS/Node 工具链，校验用 `ajv`（与服务端共用契约校验）。
- 部署：SEA 或 Docker 单产物；CI 接 `npm audit` 与 lockfile 校验。
