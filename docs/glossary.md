# 术语与编号速查

> 本仓文档里字母编号很多，这一页只做**索引**，不定义任何决策；每条都指向权威出处。

## 信任与构建

| 术语 | 含义 | 出处 |
|---|---|---|
| **DEPLOY** | 分发给用户的构建 profile；V1 bundle 仅运行 official。ADR-034 源码包可经用户确认本地安装，不要求 DEV profile | AGENTS 红线 #4、ADR-024、ADR-034 |
| **DEV-Sideload** | 开发者构建 profile（`--dart-define=ELECON_TRUST_PROFILE=dev-sideload`）：可加载未签名 adapter、可覆盖分发 base URL；不可分发 | ADR-002 §2.5、ADR-024 |
| **official** | V1 bundle 的生产信任档：由官方签名背书；不等同于新源码包的用户本地安装授权 | ADR-002 §2.2/§2.3、ADR-034 |
| **受信学校脚本 / 本地安装授权** | 用户确认学校身份、网络范围与具体内容后运行的普通 async JS；可访问当前身份凭据。授权绑定 canonical digest，不等同于官方背书 | ADR-034 |
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
| **sequence** | V1 catalog / revocation 的单调序号，防回滚；历史仪式序号与当前入库字节分别见状态源，不据旧快照断言线上版本 | ADR-018 §2.5、整改清单 §2.7 |
| **发版门（release gate）** | `release:gate` G1–G6：以客户端锚验签 bootstrap、sequence 不倒退、revocation 未过期、每个 entry 入台账；release 工作流硬失败 | P3-08、`adapter_release.md` §10 |
| **台账（ledger）** | `release/adapter-release-ledger.json`：每次 official 签发的 source commit / digest / sequence / 签署人 | P0-15、`adapter_release.md` §7 |

## 运行时

| 术语 | 含义 | 出处 |
|---|---|---|
| **Broker** | 可信核心里替 adapter 发网络请求、注入凭证的组件；B1–B6 是它的六个零件（注入策略 / 头净化 / 重定向 / cookie jar / 收割桥接 / 命令式运行时） | ADR-009、`docs/reference/b4_*` `b5_*` `b6_*` |
| **declarative / imperative** | V1 adapter 的两种 requestGraph 形态；新源码包只有普通 async handler | ADR-022、ADR-023 |
| **Masker** | V1 响应交付防火墙：Capture / Project / Commit；旧兼容路径仍保留，新源码路径不使用，尚未全局删除 | ADR-026、ADR-034 |
| **capability** | adapter 声明的能力 id（`notice.list` 等），只能来自 `contract/capability/registry.json` | ADR-001、ADR-010 §2.1 |
| **stdlib / stdlibMin** | 宿主注入的 `elecon:html` 解析库及 adapter 声明的最低版本 | ADR-011、ADR-018 §2.4 |

## 清单编号

| 前缀 | 含义 | 出处 |
|---|---|---|
| **P0 – P4** | 整改清单优先级：P0 安全与发版阻断 → P4 产品扩展 | `docs/planning/2026_08_review_remediation.md` |
| **C*/K*/M*/Q*/CH*/H*** | validator / 签收清单的检查项编号：C adapter 校验、K catalog、M ssoMint、Q query 凭证、CH 命名 header、H 加密算子安全清单 | `tools/src/validator/`、各 signoff checklist |
| **🔒** | 触红线的承重路径：AI 不得独自闭环，须人工审 + 安全清单 | AGENTS §1 |

## 新脚本格式与版本

| 字段 / 术语 | 含义 | 出处 |
|---|---|---|
| **elecon-script/1** | 新源码包的格式代际，JSON 包含 manifest 与单个 ESM source；与 V2 实验分支、V1 `elecon-bundle/3` 彼此独立 | ADR-034、`contract/script-package.schema.json` |
| **sdkVersion** | 宿主脚本 API 代际：SDK 2 使用凭据 namespace/唯一描述符；SDK 1 仅保留预览兼容语义。与单脚本更新号独立，未知代际拒绝 | ADR-034/035、`contract/script-sdk/` |
| **manifest.version** | 单个脚本的严格三段版本号；同 id 更新必须递增，相同版本不同内容拒绝 | ADR-034 |
| **schemaVersion** | capability 业务数据版本，由 schema validator 裁定；不随脚本每次修复递增 | ADR-001、ADR-034 |
| **源码包 digest** | canonical 包内容 SHA-256，绑定源码、身份与权限；本地安装确认依据，不证明官方背书或代码无缺陷 | ADR-034 |
| **应用版本** | Flutter 应用整体版本；与格式、SDK、单脚本及业务 schema 版本独立 | `client/pubspec.yaml` |
| **凭据描述符 / namespace** | SDK 2 以宿主绑定 schoolId、namespace 与 key 唯一寻址；同校共享 namespace 必须显式选择，namespace 不新增权限档 | ADR-035 |
