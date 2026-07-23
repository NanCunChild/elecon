# school-template-declarative (declarative requestGraph)

## 信息

- **学校**：模板学校
- **信任档**：sideload
- **requestGraph**：declarative（无网络、无凭证、纯解析；核心按 `requests[]` 代取）
- **已知坑**：

## 夹具说明

`fixtures/` 中的样本均已脱敏。

## 测试

```bash
# tools 为 Node/TS 工具链
cd tools && npm run validate -- --adapter=../adapters/_template/declarative
```
