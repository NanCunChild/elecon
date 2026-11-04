# Elecon 校园信息聚合平台

面向学生整合课表、成绩、通知、校园卡、图书等服务。学校差异由可更新的受信学校脚本处理，客户端负责授权、标准数据、异步执行和统一页面。

**当前开发入口**：[AGENTS](AGENTS.md) → [现行架构](docs/architecture.md)。脚本作者从 [Wiki](docs/wiki/README.md) 开始，当前状态与待办只维护在[实施计划](docs/planning/implementation.md)；[ADR](docs/adr/README.md)按需查原因，旧设计与验证流水见[档案](docs/archived/README.md)。未迁移 V1 按[兼容边界](docs/reference/legacy_compatibility.md)维护。

**开发教程**：[开发 Wiki](docs/wiki/README.md)提供快速开始、10 类卡片模板、登录与凭据保存、按钮响应、WebView/DOM、SDK 与 Flutter 组件调用，以及可打包的离线示例。

## 当前路线

`elecon-script/1` 源码包经用户检查内容、学校身份与网络范围后安装，允许未签名源码；更新重新确认。受信脚本能处理当前学校凭据、HTTP 和可见浏览器 DOM，宿主保持密钥、身份、执行 digest、取消和能力边界。SDK 2 namespace 是寻址分组，不是同校脚本间的权限隔离。

使用、模板与打包见[作者手册](docs/wiki/README.md)，学校源码见 [school-scripts](school-scripts/README.md)，西电接入见[学校说明](school-scripts/xidian/README.md)。客户端平台、真实学校与人工验收状态见[实施计划](docs/planning/implementation.md)，不以代码存在推断发布已完成。

**本科宿舍功能**：支持校园网水电多表/历史查询及空调状态与控制；研究生包不声明这些能力。新源码空调按 [ADR-046](docs/adr/adr_046_triggered_script_requests.md) 由按钮触发一次控制发送后查询状态，不额外确认、不自动重发，未知结果保留。使用与平台边界见[学校说明](school-scripts/xidian/README.md)，真实设备与核心人工验收另行记录。

## 下一步规划

本轮统一脚本运行接口、调用语义和错误处理，保留普通 ES 模块与异步函数。后续支持长期 WebView JS、自绘界面、全部能力首页入口、独立验证码/MFA 及用户启用的自动操作；实现状态、依赖与验收见[统一实施计划](docs/planning/implementation.md)。匿名增强和中继仍为独立候选，不作为当前受信扩展的前置。

## 仓库结构

| 目录 | 职责 |
|---|---|
| `contract/` | 业务 schema、registry、源码包/SDK 及 V1 兼容契约 |
| `school-scripts/` | 受信学校源码和合成协议测试 |
| `adapters/_template/trusted/` | 当前受信源码模板；HTTP 示例有学校凭据权限 |
| `client/` | Flutter 页面、会话、宿主与背景脚本运行时 |
| `server/` | public 静态签名产物分发、campus 501 stub；没有新业务中继缓存 |
| `adapters/` | 当前受信源码模板和共享 stdlib；真实 V1 学校包由 adapters.pin 固定外部仓 |
| `tests/fixtures/legacy-adapters/`、`client/test/legacy/` | V1 专用模板夹具与回归测试；整理范围见 [ADR-065](docs/adr/adr_065_repository_cleanup.md) |
| `tools/` | 打包、校验、生成器及旧签名发布工具 |
| `docs/` | 当前架构、ADR、规则、研究、规划与 archived 历史 |

## 本地运行

```bash
cd client
fvm flutter pub get
fvm flutter run
```

Apple 构建使用 `bash tool/with_apple_pubspec.sh flutter run --target lib/main_apple.dart`。HarmonyOS 见 [client/ohos](client/ohos/README.md)，平台能力以实际验收为准。

在仓库根运行 `npm ci` 安装 workspace 工具依赖。`npm run dev:public -w server` 启动现有静态分发服务，`npm run dev:campus -w server` 仅启动尚未实现查询的中继骨架。新源码目前没有服务端生产执行器。

## 贡献与许可

先读 [AGENTS](AGENTS.md)和[工作流](docs/rules/feature_workflow.md)。用合成/脱敏夹具，CI 不请求真实学校或设备。核心、凭据、网络、控制与签名变更须人工实质审阅后合并。

仓库许可证见 [LICENSE](LICENSE)，学校源码及新增依赖按各自声明；新依赖先确认许可和分发边界。
