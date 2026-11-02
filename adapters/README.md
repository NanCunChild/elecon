# 学校脚本模板与共用资源

新学校接入使用受信源码包：从 [`_template/trusted/`](_template/trusted/) 选择 HTTP、浏览器或签到模板，实际学校源码放在 [`school-scripts/`](../school-scripts/)。包格式、SDK 和安装步骤见[受信脚本文档](../docs/reference/trusted_scripts.md)。学校脚本可以处理当前授权学校的凭据；宿主负责执行授权、身份、网络和资源边界。

| 目录 | 用途 |
|---|---|
| `_template/trusted/http` | 受限 HTTP 与本校授权凭据示例 |
| `_template/trusted/browser` | 前台可见浏览器认证示例 |
| `_template/trusted/attendance` | 通用前台请求与签到输入示例 |
| `_stdlib` | 固定版本 HTML 解析器；当前脚本和保留的 V1 运行时共用 |
| `school-helloworld` | 仍被签名分发诊断使用的 V1 示例，不是新接入起点 |

旧 declarative/imperative 模板和引擎 canary 已转为 [`tests/fixtures/legacy-adapters`](../tests/fixtures/legacy-adapters/README.md) 测试资产，不再作为新学校模板或随模板镜像分发。现有 V1 执行器、签名 bootstrap 和公开仓 adapter 回归仍保留，见[兼容维护边界](../docs/reference/legacy_compatibility.md)及 [ADR-065](../docs/adr/adr_065_repository_cleanup.md)。
