# Elecon 校园信息聚合平台

面向学生整合课表、成绩、通知、校园卡、图书等服务。学校差异由可更新的受信学校脚本处理，客户端负责授权、标准数据、异步执行和统一页面。

**当前开发入口**：[AGENTS](AGENTS.md) → [架构](docs/architecture.md) → [ADR 状态](docs/adr/README.md)。旧 ADR-000–033 与总则已[废弃归档](docs/archived/README.md)，不再作为新接入的默认指南；未迁移 V1 按[兼容边界](docs/reference/legacy_compatibility.md)维护。

## 当前路线

`elecon-script/1` 源码包经用户检查内容、学校身份与网络范围后安装，允许未签名源码；更新重新确认。受信脚本能处理当前学校凭据、HTTP 和可见浏览器 DOM，宿主保持密钥、身份、执行 digest、取消和能力边界。SDK 2 namespace 是寻址分组，不是同校脚本间的权限隔离。

使用、模板与打包见[受信脚本参考](docs/reference/trusted_scripts.md)，学校源码见 [school-scripts](school-scripts/README.md)，西电接入见[学校说明](school-scripts/xidian/README.md)。客户端平台、真实学校与人工验收状态见[实施记录](docs/planning/trusted_scripts.md)，不以代码存在推断发布已完成。

**2026-10-31 本科宿舍功能**：客户端 0.5.0+8、SDK 5 本科包 0.14.0 增加校园网水电多表/历史查询和空调状态/确认控制；研究生不新增这些能力。方案见 [ADR-040](docs/adr/adr_040_energy_and_trusted_climate.md)，使用与平台边界见[学校说明](school-scripts/xidian/README.md)。校园网/真实设备与核心人工安全验收另行记录。

## 下一步规划

[ADR-042](docs/adr/adr_042_providers_pages_enhancements.md)规划独立页面与可选择的增强包。[ADR-043](docs/adr/adr_043_card_layout_and_overrides.md) 已实现同名能力覆盖与首页长按编辑、拖动排序、有限尺寸调整，见[使用说明](docs/reference/card_layout_and_overrides.md)；匿名增强和中继仍未实现。课表与课程标准分开建模；图书搜索不复用个人借阅语义，论坛不冒充通知。公开通知是中继缓存的首个试点，空教室先核实共享授权，水电按身份与表具隔离。

- [模板与接口审计](docs/reference/interface_evolution.md)
- [中继研究与可复现实验](docs/research/relay_enhancement_feasibility.md)
- [分期实施与验收](docs/planning/platform_evolution.md)

## 仓库结构

| 目录 | 职责 |
|---|---|
| `contract/` | 业务 schema、registry、源码包/SDK 及 V1 兼容契约 |
| `school-scripts/` | 受信学校源码和合成协议测试 |
| `adapters/_template/trusted/` | 当前受信源码模板；HTTP 示例有学校凭据权限 |
| `client/` | Flutter 页面、会话、宿主与背景脚本运行时 |
| `server/` | public 静态签名产物分发、campus 501 stub；没有新业务中继缓存 |
| `adapters/` | V1 模板/stdlib/canary；真实 V1 学校包由 adapters.pin 固定外部仓 |
| `tools/` | 打包、校验、生成器及旧签名发布工具 |
| `docs/` | 当前架构、ADR、规则、研究、规划与 archived 历史 |

## 本地运行

```bash
cd client
flutter pub get
flutter run
```

Apple 构建使用 `bash tool/with_apple_pubspec.sh flutter run --target lib/main_apple.dart`。HarmonyOS 见 [client/ohos](client/ohos/README.md)，平台能力以实际验收为准。

在仓库根运行 `npm ci` 安装 workspace 工具依赖。`npm run dev:public -w server` 启动现有静态分发服务，`npm run dev:campus -w server` 仅启动尚未实现查询的中继骨架。新源码目前没有服务端生产执行器。

## 贡献与许可

先读 [AGENTS](AGENTS.md)和[工作流](docs/rules/feature_workflow.md)。用合成/脱敏夹具，CI 不请求真实学校或设备。核心、凭据、网络、控制与签名变更须人工实质审阅后合并。

仓库许可证见 [LICENSE](LICENSE)，学校源码及新增依赖按各自声明；新依赖先确认许可和分发边界。
