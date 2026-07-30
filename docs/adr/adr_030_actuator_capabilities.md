# ADR-030：用户主动触发的物理副作用 Capability

- **状态**：提议（Proposed，未授权实现）；owner 已评审并接受主体（2026-07-29，见 §8），四点细化并入 §3/§5/§8
- **日期**：2026-07-29
- **适用范围**：设备控制等 mutation/actuator capability
- **触及红线**：#1、#5、#6、#10

## 1. 背景

XIDIAN 聚好联探针提供状态查询和 `POST /api/device/direct/command`。IMEI 定位设备，当前探针还要求
`x-access-token`。现有 `ctx.fetch` 技术上能发 POST，但普通读取执行模型没有用户手势证明、确认、幂等、
禁重试和结果未知语义。探针中的定时执行与最多三次重试尤其不能迁入正式 adapter。

## 2. 提议的能力

- `climate.devices`：返回当前用户可见的设备和支持的有限控制项；
- `climate.status`：只读查询电源、模式、风速、设定/室内温度及在线状态；
- `climate.command`：仅接受 `deviceId` 和一个有限命令，不接受任意 URL/header/body。

`deviceId` 可由 XIDIAN IMEI 映射，但 schema 只使用中性名称。IMEI 属设备标识，不得写入 fixture、诊断或
跨用户缓存。

## 3. 核心门禁

`climate.command` 必须使用独立 action 执行入口：

- 仅由当前前台明确用户手势触发；
- 规范化命令、设备、adapter digest 与一次性确认 token 绑定；
- 禁后台刷新、定时器、自动执行和 adapter 内循环——**该禁令只约束 `climate.command`（mutation）**；只读的
  `climate.status` 刷新语义见 §5.1（生命周期点刷新 ≠ 后台周期轮询）；
- 一次 action 最多发送一个 mutation 请求；
- **禁止自动重试**（网络差时静默重发会放大误操作与状态漂移）；MVP 禁止所有重定向。action 失败（含
  `unknown`）时**不自动重发命令**，而是提醒用户并触发一次独立 `climate.status` 同步以呈现真实设备态（见 §5.2）；
- 超时或连接中断返回 `unknown`，随后由独立 `climate.status` 核验；
- **先操作后同步，禁乐观更新**：UI 不得在收到确认前抢先反映目标态；命令返回后经 `climate.status`
  核验，UI 只反映核验回来的真实态（见 §5.2）；
- 固定 HTTPS origin/path，参数经可信核心按 schema 校验；
- **release official-only、dev 侧载等同 official**（红线 #5 dev 例外 / ADR-002 §2.5，见 §8.4）；
  Android-first、client-direct；iOS 在专项合规复评前不加载 command。

首版命令限定为：开/关机、设定温度、模式、风速、扫风、强力和辅热。温度范围及枚举由设备 discovery
结果和 contract 双重约束。不得提供原始 JSON command 通道。

## 4. 凭证预留

XIDIAN 当前协议的 `x-access-token` 按 ADR-029 建模；若该值由学校响应返回，则按 ADR-026 收割到核心并从 adapter-visible 响应投影删除。即使某环境暂时只凭 IMEI 可调用，正式 manifest
也不得假定 IMEI 永久等价于授权；核心与 contract 必须允许未来将 command 收紧为具名 header credential。
缺少要求的 credential 时 fail-closed。

## 5. 结果语义

command 结果至少区分 `accepted`、`applied`、`rejected`、`unknown`，可选携带核心生成的
`commandId`/`idempotencyKey`。HTTP 2xx 不自动等于 `applied`；只有后端明确确认或后续状态核验才能使用该值。

### 5.1 状态刷新的生命周期语义（owner 决议 §8.1）

`climate.status` 是只读能力，其刷新与 §3 对 `climate.command` 的「禁后台/定时/自动」禁令**正交**。核心须在
**明确的生命周期点**发起一次状态同步，而非常驻后台周期轮询：

- **应用初始化 / 登录完成**：同步一次设备状态（让首页/入口具备可信初值）；
- **进入空调控制界面（首次挂载）**：同步一次；
- **控制界面每次可见（前台 resume / 重新可见）**：刷新一次。

禁止：不在控制界面前台可见时的定时器轮询、adapter 内自循环、以及把刷新伪装成 command 的旁路。刷新失败
fail-closed 呈现「状态未知」，不得沿用陈旧值冒充实时态。

### 5.2 失败处理与「先操作后同步」（owner 决议 §8.2 / §8.3）

- **禁乐观更新**：发出 command 后，UI 不得抢先把控件切到目标态。目标态只在 `climate.status` 核验回来后反映。
- **失败不自动重试**：command 返回 `rejected`/`unknown` 或传输失败时，核心**不自动重发命令**（避免网络差时
  重复触发物理副作用）。而是：① 明确提醒用户操作可能未生效；② 触发一次独立 `climate.status` 同步，把设备
  真实态回填 UI，由用户决定是否再次手势触发。
- 「同步」始终指只读 `climate.status`，与 mutation 严格分离；失败路径**永不**演变为命令重试。

## 6. 测试要求

- CI 只使用 fake transport，禁止访问真实设备；
- 覆盖连点、超时、redirect、adapter 尝试二次 command、非法 IMEI/温度/枚举和凭证回显；
- fixture 使用虚构设备 ID，禁止真实 IMEI/token；
- Dart/TS action policy 共用 golden。

## 7. 未决事项

1. 聚好联 command 是否支持服务端幂等键。
2. token 的上游取得和刷新流程；响应内收割与投影机制由 ADR-026 统一承接。
3. IMEI 是否必须先由可信 discovery 绑定，还是允许用户手工录入并本地保存。
4. `climate.status` 是否可在无 token 环境单独开放。

## 8. Owner 评审决议（2026-07-29）

Owner 接受本 ADR 主体，附以下四点细化（已并入 §3/§5，此处记录理由，供实现期回溯）：

### 8.1 区分后台刷新

「禁后台刷新」只针对 mutation。只读状态须在三个生命周期点主动同步：**应用初始化/登录一次、进入控制界面
一次、界面每次可见都刷新**。这既保证用户看到的永远是最近一次可见时的真实态，又不引入常驻后台轮询。细则见 §5.1。

### 8.2 禁自动重试 + 失败即提醒并同步

网络差时静默重试会同时放大两类风险：状态同步漂移与物理误操作（命令被重复投递）。故**禁一切自动重试**。
但失败不能沉默——须**提醒用户**并**触发一次 `climate.status` 同步**回填真实态，把「是否再来一次」交回用户手势。细则见 §5.2。

### 8.3 先操作后同步，禁乐观更新

UI 一律「操作 → 核验 → 反映」，不做「先反映目标态再对账」。乐观更新在 unknown/失败语义下会给出与设备不符的
假象，与 §5「2xx≠applied」同源。细则见 §5.2。

### 8.4 official-only 的真实边界：release official-only、dev 侧载等同 official

- **release**：`climate.command` 为 official-only。但需澄清其**边界**——official-only **并不能、也不试图
  禁止一个声明式 adapter *构造*到设备端点的请求**（declarative requestGraph 只要 allow-list 允许即可声明任意
  URL 的请求，这是既定语义，红线 #5 未禁止声明式 adapter 发请求）。因此 mutation 的真实护栏**不是**「别人无法
  形成这个请求」，而是三层叠加：
  1. **凭证托管 fail-closed**（§4）：`x-access-token` 等授权凭证只经 official command 的独立 action 入口注入；
     任何绕过该入口的裸声明式请求缺凭证 → 设备侧/核心侧 fail-closed。**这是承重护栏**。
  2. **命令 action 闸门**（§3）：手势证明、一次性确认 token、单请求、禁重试/重定向等安全语义只存在于该专用入口；
     声明式请求即使发出也拿不到这套语义，无法冒充「一次经确认的用户操作」。
  3. **能力注册档位**：`climate.command` 在 release 只对 official trust tier 放行执行入口。
- **dev/debug**：按红线 #5 dev 例外与 ADR-002 §2.5，无签名侧载 adapter 能力**等同 official**（可跑 imperative、
  可触发凭证注入），故 dev 下侧载 adapter 亦可加载并执行 `climate.command`，与 official 同权。该「允许」分支
  `kReleaseMode` 条件编译内，release 二进制不存在。

**推论（给实现与安全审）**：核心不得把「official-only」实现成「校验请求 URL 是否属于 command 端点并拦截非
official」——那既做不到（声明式可换 URL/参数）也无必要。正确实现是：把 mutation 语义与凭证注入**收敛到唯一的
official-gated action 入口**，其余路径缺凭证自然 fail-closed。

---

在人工接受本 ADR、配套 contract 和核心门禁落地前，不得在正式 adapter 中声明 `climate.command`。
