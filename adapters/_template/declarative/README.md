# school-template-declarative (declarative requestGraph)

## 信息

- **学校**：模板学校
- **信任档**：sideload
- **requestGraph**：declarative（无网络、无凭证、纯解析；核心按 `requests[]` 代取）
- **已知坑**：

## 声明式跨请求数据流示例（ADR-023）

本模板 `grades.list` 演示「挑战页 → 派生值 → 注入下一跳」这类数据依赖链，全程 **broker 侧**执行、adapter 永不见值：

1. `requests.chal` 先取挑战页（无凭证、passthrough）。
2. `bind.client_id`：用 `regex` 从 `chal` 响应体抽出 `client_id`，绑为不透明句柄。
3. `inject`：把 `client_id` 注入 `raw` 请求 URL 的 `cid` 参数（**静态汇聚点**，绝不依值选择注入到哪）。注入到 `at: url` 时 broker **自动 component 编码**，故无需 `urlencode` compute。

> **V1 legacy template**：V2 已退役 declarative dataflow，不得用于新 adapter。历史逐 op 语义见 [`declarative_dataflow_ops.md`](../../../docs/reference/archived/v1/declarative_dataflow_ops.md)。

`index.js` 的解析函数只读 `responses.raw` 是 V1 行为。V2 使用统一异步 JavaScript；本模板将在 V2 adapter 迁移后删除。历史语义见 [`docs/reference/declarative_dataflow_ops.md`](../../../docs/reference/archived/v1/declarative_dataflow_ops.md)。

## 夹具说明

`fixtures/` 中的样本均已脱敏。

## 测试

```bash
# tools 为 Node/TS 工具链
cd tools && npm run validate -- --adapter=../adapters/_template/declarative
```
