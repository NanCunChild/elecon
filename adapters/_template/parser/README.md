# school-template-parser (parser 模式)

## 信息

- **学校**：模板学校
- **信任档**：sideload
- **模式**：parser（无网络、无凭证、纯解析器）
- **已知坑**：

## 夹具说明

`fixtures/` 中的样本均已脱敏。

## 测试

```bash
# tools 为 Node/TS 工具链
cd tools && npm run validate -- --adapter=../adapters/_template/parser
```
