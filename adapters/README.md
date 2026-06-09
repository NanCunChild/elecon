# adapters/ — 学校 adapter 目录

> adapter 的唯一职责：把某校后端返回的数据归一化成标准 schema。
> **越薄越好**——只做归一化，不持凭证、不做编排。

## 目录约定

```
adapters/
  _template/        脚手架模板（fetch 和 parser 两种模式）
    fetch/          → 官方签名 adapter 模板
    parser/         → 第三方/侧载 adapter 模板
  school-<id>/      各学校 adapter
    manifest.json
    index.js
    fixtures/       脱敏的抓包样本
    README.md       该校信息与已知坑
```

## 快速开始

```bash
# 从模板复制
cp -r adapters/_template/fetch adapters/school-<你的学校id>

# 修改 manifest.json 声明能力 + 域名白名单
# 在 index.js 实现归一化
# 在 fixtures/ 放入脱敏抓包样本

# 校验（tools 为 Node/TS 工具链）
cd tools && npm run validate -- --adapter=../adapters/school-<id>
```

## 信任级别

| trustTier | mode | 能做什么 |
|---|---|---|
| `official` | `fetch` | 受限取数（仅白名单内域名注入凭证） |
| `community` | 待 adr_002 细化 | — |
| `sideload` | `parser`（强制） | 纯解析器，无网络、无凭证、无副作用 |
