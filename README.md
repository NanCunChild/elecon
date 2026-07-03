# Elecon · 校园信息聚合平台

一个面向学生的校园信息聚合应用。它把成绩、课表、一卡通、图书馆等分散在不同学校后端的信息，归一化后聚合到一处。架构的第一目标不是功能最大化，而是**在最少的人力下，对学校接口的频繁变动与多平台差异保持韧性**。

---

## 它解决什么

- **学校接口频繁变动** → 把对接逻辑沉成可热替换的 adapter，接口一改推新 adapter 即可，**无需发版**。
- **维护人力不足 / 社区难参与** → 贡献者只需写一个 JS 文件（adapter），客户端与服务端共用，门槛最低。
- **合规与安全** → 私密数据永远走客户端直连或校内授权环境，**公网组件不持有任何凭证**。
- **多平台割裂（iOS / Android / HarmonyOS）** → 保留 Flutter UI，传输/数据/UI 三层各自可替换。

---

## 架构速览

```
        UI 层（数据驱动 / SDUI，只认"标准 schema"）
                       │
        可信核心 Core —— 凭证保管 · Capability Broker · 插件信任 · 版本/时效
            │                                   │
   数据 adapter（QuickJS 脚本，热替换）    传输底座（原生，仅官方签名）
            │                                   │
   ┌────────┴─────────┐                ┌────────┴─────────┐
   │ 校内授权中继 campus │                │  公网哑服务 public │
   │ 堡垒机后·代取私密   │                │ 无状态·发adapter+  │
   │                  │                │ 缓存公开数据·零凭证 │
   └──────────────────┘                └──────────────────┘
```

**两条要记住的原则：**

1. **公网服务端是"哑"的**——只发 adapter、只缓存公开数据，永不持凭证。它同时解决了成本、合规、安全。
2. **一份 adapter，两端运行**——客户端用 QuickJS、服务端用 QuickJS-wasm 跑同一份脚本（同一个引擎、零语义漂移），归一化逻辑只写一次。

完整路线与取舍见 [`docs/adr/adr_000_abstract.md`](docs/adr/adr_000_abstract.md)；目录与职责见下方[「仓库结构」](#仓库结构)与各子目录的 `README.md`，开发总则见 [`AGENTS.md`](AGENTS.md)。

---

## 仓库结构

```
contract/   跨端共享契约：标准 schema + capability manifest + adapter SDK（最重要的一层）
adapters/   各学校 adapter（QuickJS 脚本）
client/     Flutter 客户端（iOS / Android / HarmonyOS / 桌面）
server/     Node/TS 服务端：public（公网哑服务）+ campus（校内授权中继），adapter 用 QuickJS-wasm 执行
tools/      Node/TS 工具链：签名 / 吊销 / adapter 校验 / 契约一致性检查
docs/       ADR 与工程结构说明
```

---

## 构建与运行

### 客户端（Flutter）

```bash
cd client
flutter pub get
flutter run                 # iOS / Android / 桌面
```

**HarmonyOS：** 用 FVM 管理多版本 SDK，平时用官方版保持主线纯净，仅在打包鸿蒙时切到 OHOS 分支 SDK，鸿蒙特有依赖用 `dependency_overrides` 替换。详见 `client/ohos/README`。

### 服务端（Node / TypeScript）

```bash
cd server
npm install
npm run dev:public          # 公网哑服务：分发 adapter + 缓存公开数据
npm run dev:campus          # 校内授权中继：堡垒机后部署
npm run typecheck           # TypeScript 类型检查
npm run smoke:broker        # Broker B1 注入策略 smoke（12 例 golden）
npm run smoke:header        # B2 头净化 smoke（12 例）
npm run smoke:redirect      # B3 重定向 smoke（14 例 + driver 4）
npm run smoke:cookie        # B4 cookie jar smoke（22 例 + 有态 6）
npm run smoke:harvest       # B5 收割桥接 smoke（8 例 + 集成 4）
npm run smoke:credential    # 凭证存储 smoke
```

> adapter 在服务端用 **QuickJS-wasm**（`quickjs-emscripten`）执行，与客户端是同一个引擎；**不使用** Node 的 `vm` 模块（`vm` 不是安全边界）。运行时选型见 [`docs/adr/adr_005_runtime.md`](docs/adr/adr_005_runtime.md)。

---

## 贡献一个学校 adapter

1. 复制 `adapters/_template/` 为 `adapters/school-<你的学校id>/`。
2. 在 `manifest.json` 声明能力与**域名白名单**（核心据此注入凭证，越界请求不带凭证）。
3. 在 `index.js` 实现归一化：把该校接口返回的数据转成 `contract/schema/` 定义的标准结构。**adapter 越薄越好——只做归一化，不持凭证、不做编排。**
4. 在 `fixtures/` 放抓包样本，写归一化回归测试。
5. 在该 adapter 的 `README.md` 记录：该校属哪一档（UA 门禁 / CAS 逃生口 / openid 唯一身份 / 微信小程序）及已知坑。

**信任级别：** 官方签名 adapter 可用"能力限定的取数"；第三方/侧载 dev adapter 在客户端退化为**纯解析器**（无网络、无凭证），且仅在 debug build / 显式开发者模式下可加载，release 包从编译期拒绝。

---

## 合规与安全

- **客户端直连为基线**：私密、认证相关的数据走客户端直连或校内授权中继，**不经公网服务器**。
- **凭证零泄露给插件**：cookie/token 只存于可信核心，adapter 通过受限方法访问数据，拿不到凭证的值，也拿不到任何等价于凭证的东西（带 token 的 URL、`Set-Cookie`、重定向中间 token 等均不暴露）。
- **传输底座最高门槛**：能看到全部流量的传输底座仅接受官方签名，release 无侧载入口。
- **显式知情同意**：启用能看到全部流量的隧道时，提供独立且更重的告知与授权流。

> 涉及第三方协议复刻（如校园 VPN）的接入，需先完成"许可证 + 协议模式 + iOS 可行性"评估，并以可热替换的传输底座形式接入，不焊死在客户端。

---

## 路线状态

架构决策已接受至 ADR-016。当前处于 **fetch 模式运行时已跑通、登录/分发链路补齐阶段**：

- **已落地**：Broker 核心零件 B1–B6 两端（TS + Dart）镜像实现；凭证存储原型；`setEphemeralCookie` 契约面；首个真实 fetch adapter（school-xjt `notice.list`）夹具回放端到端跑通。
- **进行中**：录制/回放夹具机制（B7）；WebView 登录收割探针（XIDIAN 凭证路径前置）；OHOS 平台 scaffold 与 debug-only WebView probe。
- **待补齐**：真实 OS keystore 凭证存储、官方签名/吊销工具、public adapter 分发、campus relay、产品 UI 数据闭环。

细分决策与取舍见 `docs/adr/` 索引；实现计划见 `docs/reference/`。

---

## 许可证

见 [`LICENSE`](LICENSE)。注意：若接入 GPL 系第三方组件（如某些 VPN 协议复刻），需做实进程/模块边界隔离以避免传染，相关分析见对应 ADR。
