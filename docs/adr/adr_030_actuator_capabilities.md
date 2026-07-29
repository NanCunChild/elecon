# ADR-030：用户主动触发的物理副作用 Capability

- **状态**：提议（Proposed，未授权实现）
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
- 禁后台刷新、定时器、自动执行和 adapter 内循环；
- 一次 action 最多发送一个 mutation 请求；
- 禁止自动重试，MVP 禁止所有重定向；
- 超时或连接中断返回 `unknown`，随后由独立 `climate.status` 核验；
- 固定 HTTPS origin/path，参数经可信核心按 schema 校验；
- official-only、Android-first、client-direct；iOS 在专项合规复评前不加载 command。

首版命令限定为：开/关机、设定温度、模式、风速、扫风、强力和辅热。温度范围及枚举由设备 discovery
结果和 contract 双重约束。不得提供原始 JSON command 通道。

## 4. 凭证预留

XIDIAN 当前协议的 `x-access-token` 按 ADR-029 建模。即使某环境暂时只凭 IMEI 可调用，正式 manifest
也不得假定 IMEI 永久等价于授权；核心与 contract 必须允许未来将 command 收紧为具名 header credential。
缺少要求的 credential 时 fail-closed。

## 5. 结果语义

command 结果至少区分 `accepted`、`applied`、`rejected`、`unknown`，可选携带核心生成的
`commandId`/`idempotencyKey`。HTTP 2xx 不自动等于 `applied`；只有后端明确确认或后续状态核验才能使用该值。

## 6. 测试要求

- CI 只使用 fake transport，禁止访问真实设备；
- 覆盖连点、超时、redirect、adapter 尝试二次 command、非法 IMEI/温度/枚举和凭证回显；
- fixture 使用虚构设备 ID，禁止真实 IMEI/token；
- Dart/TS action policy 共用 golden。

## 7. 未决事项

1. 聚好联 command 是否支持服务端幂等键。
2. token 的取得和刷新流程。
3. IMEI 是否必须先由可信 discovery 绑定，还是允许用户手工录入并本地保存。
4. `climate.status` 是否可在无 token 环境单独开放。

在人工接受本 ADR、配套 contract 和核心门禁落地前，不得在正式 adapter 中声明 `climate.command`。
