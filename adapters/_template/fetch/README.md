# school-template (fetch 模式)

## 信息

- **学校**：模板学校
- **信任档**：official
- **模式**：fetch
- **已知坑**：无

## 夹具说明

`fixtures/` 中的样本均已脱敏。

## 测试

```bash
# 运行此 adapter 的归一化回归测试（tools 为 Node/TS 工具链）
cd tools && npm run validate -- --adapter=../adapters/_template/fetch
```
