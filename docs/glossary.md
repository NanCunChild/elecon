# 术语与编号速查

> 本仓文档里字母编号很多，这一页只做**索引**，不定义任何决策；每条都指向权威出处。

## 信任与构建

| 术语 | 含义 | 出处 |
|---|---|---|
| **DEPLOY** | 分发给用户的构建 profile：只运行 official 签名 adapter，无侧载入口 | AGENTS 红线 #4、ADR-024 |
| **DEV-Sideload** | 开发者构建 profile（`--dart-define=ELECON_TRUST_PROFILE=dev-sideload`）：可加载未签名 adapter、可覆盖分发 base URL；不可分发 | ADR-002 §2.5、ADR-024 |
| **official** | 唯一的生产信任档：由离线 YubiKey 签名 | ADR-002 §2.2/§2.3 |
| **信任域 A / B / C / D** | A 社区源码仓（elecon-adapters）· B 审查/打包沙箱 · C 离线签名 · D 公网分发端点 | ADR-018 §2 表 |
| **端点 D / base URL** | 静态托管的 `catalog.json.gz` + `revocation.json` + `bundles/<digest>.json.gz`；base URL 由客户端自持，catalog 不描述端点 | ADR-018 §2.5.1、`deploy/public-endpoint/` |
| **bootstrap** | 随 app 打包的签名基线（`client/assets/bootstrap/`），**唯一入库的签名产物**；dist 树由它 `dist:export` 导出 | ADR-018 §2.6、`tools/README.md` |
| **信任锚 / pin** | 编译进 app 的 Ed25519 公钥集；任何下发数据都不能引入新公钥 | ADR-002 §2.3、`trust_anchors.dart` |

## 包与签名

| 术语 | 含义 | 出处 |
|---|---|---|
| **数据信封** | 运行期 adapter→宿主的归一化外包装 `{schema, schemaVersion, source, freshness, data}` | ADR-000 §2.3.1、ADR-001 §3.3 |
| **bundle 信封** | 签发期 adapter 包清单（文件路径/大小/哈希），`digest = SHA-256(信封字节)`，Ed25519 签的就是它 | ADR-018 §2.9.1 |
| **信封加密** | 密钥管理通名：DEK 加密数据、KEK 包装 DEK；与上两者只是撞名 | ADR-012 §2.8 |
| **传输封套** | 上线三字段对象 `{envelopeB64, signature, blobs}`；catalog / revocation 的外层同构 | ADR-018 §2.9.1 |
| **digest v2** | 对 bundle 信封字节整体哈希（v1 只哈希内容、不覆盖路径，已被保序重命名攻击击穿） | ADR-002 §2.3、`docs/archive/bundle_digest_v1_superseded.md` |
| **sequence** | catalog / revocation 的单调序号，防回滚；线上现为 catalog 8 / revocation 2 | ADR-018 §2.5、整改清单 §2.7 |
| **台账（ledger）** | `release/adapter-release-ledger.json`：每次 official 签发的 source commit / digest / sequence / 签署人 | P0-15、`adapter_release.md` §7 |

## 运行时

| 术语 | 含义 | 出处 |
|---|---|---|
| **Broker** | 可信核心里替 adapter 发网络请求、注入凭证的组件；B1–B6 是它的六个零件（注入策略 / 头净化 / 重定向 / cookie jar / 收割桥接 / 命令式运行时） | ADR-009、`docs/reference/b4_*` `b5_*` `b6_*` |
| **declarative / imperative** | adapter 两种取数形态：声明式 requestGraph（宿主执行）/ 命令式 `ctx.fetch`（脚本执行） | ADR-022、ADR-023 |
| **Masker** | 响应交付防火墙：Capture 凭证 / Project 投影给 adapter / Commit 事务提交 | ADR-026 |
| **capability** | adapter 声明的能力 id（`notice.list` 等），只能来自 `contract/capability/registry.json` | ADR-001、ADR-010 §2.1 |
| **stdlib / stdlibMin** | 宿主注入的 `elecon:html` 解析库及 adapter 声明的最低版本 | ADR-011、ADR-018 §2.4 |

## 清单编号

| 前缀 | 含义 | 出处 |
|---|---|---|
| **P0 – P4** | 整改清单优先级：P0 安全与发版阻断 → P4 产品扩展 | `docs/planning/2026_08_review_remediation.md` |
| **C*/K*/M*/Q*/CH*/H*** | validator / 签收清单的检查项编号：C adapter 校验、K catalog、M ssoMint、Q query 凭证、CH 命名 header、H 加密算子安全清单 | `tools/src/validator/`、各 signoff checklist |
| **🔒** | 触红线的承重路径：AI 不得独自闭环，须人工审 + 安全清单 | AGENTS §1 |
