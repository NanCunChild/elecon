# school-template-imperative (imperative requestGraph)

## 信息

- **学校**：模板学校
- **信任档**：official
- **requestGraph**：imperative（adapter 经 `ctx.fetch` 自取，异步 handler）
- **已知坑**：无

## 夹具说明

`fixtures/` 中的样本均已脱敏。

## 测试

```bash
# 运行此 adapter 的静态校验（tools 为 Node/TS 工具链）
cd tools && npm run validate -- --adapter=../adapters/_template/imperative
```
