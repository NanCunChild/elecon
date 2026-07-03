# contract/ — 跨端共享契约

> **这是整个项目最重要的目录。** adapter 与 UI 之间唯一的耦合面就在这里。
> 改动必须走 ADR，默认保持向后兼容（红线 #6）。

## 目录

```
schema/          JSON Schema 定义（Draft 2020-12），所有数据域的唯一事实来源
capability/      capability id 注册表（registry.json）
manifest.schema.json   manifest 自身的 JSON Schema（供 tools/ 校验）
adapter-sdk/     adapter 开发者参考（ctx 类型声明）
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
