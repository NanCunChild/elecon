# contract/ — 跨端共享契约

> **这是整个项目最重要的目录。** adapter 与 UI 之间唯一的耦合面就在这里。
> 改动必须走 ADR，默认保持向后兼容（红线 #6）。

## 目录

```
schema/          JSON Schema 定义（Draft 2020-12），所有数据域的唯一事实来源
capability/      capability id 注册表（registry.json）
script-package.schema.json   ADR-034 源码包格式（客户端独立执行路径）
script-sdk/      新受信脚本 SDK：真实凭据、宿主 HTTP 与可见浏览器 API
manifest.schema.json   V1 manifest 自身的 JSON Schema（供 tools/ 校验）
response-masker.schema.json   V1 Broker 收割与投影策略（ADR-026；兼容保留）
adapter-sdk/     V1 adapter 开发者参考（ctx 类型声明）
```

## 使用

- adapter 产出数据由宿主（Dart / TypeScript）按 `schema/` 校验后才被接受。
- 新增 capability id 或新域 schema → 走慢车道（先开 ADR）。

## 顶层原则

| 约定 | 说明 |
|---|---|
| 时间 | RFC3339, UTC (`...Z`) |
| 金额 | 整数 + 最小货币单位，禁止浮点 |
| 缺失 | 字段缺失 ≠ `null`，语义不同 |
| ID | 校内作用域字符串 |
| 枚举 | 未知值 → `"unknown"` |
| 兼容 | 新增可选字段 = 兼容；删除/改义/改类型 = 破坏性 |

## 两条执行路线

新功能以 [ADR-034](../docs/adr/adr_034_trusted_school_scripts.md) 的源码路径为准：用户确认内容后安装 `elecon-script/1`，统一 async handler 可读写当前学校身份凭据；客户端是唯一生产执行面。tools 检查与打包，不运行学校代码。源码包不声明 V1 requestGraph、credentials 配方或 masker.json。

V1 `manifest.schema.json`、`adapter-sdk/`、Masker 与 golden 仍约束尚未迁移的 official bundle。旧边界继续执行，不能把其 official-only 或凭据不可见要求套给新源码包；Masker 尚未全局删除。两条路线共享 `schema/` 业务输出与 UI。

`format`（elecon-script/1）、`sdkVersion`（宿主 API）、`manifest.version`（单脚本更新）、capability 的 `schemaVersion`（业务输出）及应用版本相互独立。不要为脚本接口修复改动业务 schema 版本，也不要把 V2 分支名当作格式或应用版本号。安装版本与 digest 行为见 [使用文档](../docs/reference/trusted_scripts.md)。

SDK 2 的凭据地址与写入语义见 [ADR-035](../docs/adr/adr_035_script_credential_identity.md)：namespace 默认脚本 id，记录 id/namespace/key 可往返；同校显式共享仍在同一授权身份内。SDK 1 为已有预览包保留原有寻址，不静默升级或猜测旧记录归属。
