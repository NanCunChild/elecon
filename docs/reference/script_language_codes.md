# 脚本作者语言代码核对表

语言资源属于脚本安装包，作者自行选择适配的语言。核心支持哪些界面语言，不限制脚本可以提供哪些语言；有代码记录也不表示 elecon 已经为该语言完成翻译。

## 官方来源

| 核对内容 | 官方入口 | 用法 |
|---|---|---|
| 完整语言、文字系统、地区、变体和废弃替代值 | [IANA Language Subtag Registry](https://www.iana.org/assignments/language-subtag-registry/language-subtag-registry) | 查 `Type`、`Subtag`、`Description`、`Deprecated`、`Preferred-Value` |
| BCP 47 标签结构与大小写惯例 | [RFC 5646](https://www.rfc-editor.org/rfc/rfc5646.html) | 语言、文字系统和地区按顺序用连字符连接 |
| ISO 639-1/639-2 名称及二/三字母代码对照 | [美国国会图书馆官方代码表](https://www.loc.gov/standards/iso639-2/php/code_list.php) | 便于按语言名查找，最终包标签仍按 IANA/BCP 47 核对 |

仓库提供[两字母语言核对 CSV](iana_language_codes.csv)，可直接在编辑器或表格软件中搜索。它从 IANA `File-Date: 2026-09-17` 的注册表提取全部 190 条两字母 language 记录，保留英文官方名称、Suppress-Script、废弃日期和替代值。记录数包含废弃标签，不是当前语言支持数量。完整三字母语言和其他子标签请查上面的官方全表；不要把 CSV 当作白名单。

提取源 SHA-256：`755fad43283be7b41ebe3c89ad054b6eaf928f404f9c0edb74799e0eab74beb1`；核对日期 2026-11-03。CSV 是注册事实的参考摘录，不是另一套语言标准，不参与安装时联网或运行时授权。更新时保留官方字段并同时更新日期/hash，不根据显示名称自行创造代码。

## 常用标签

| 语言 | 基础标签 | 可按实际译文选择的细分标签 |
|---|---|---|
| 中文 | `zh` | `zh-Hans` 简体、`zh-Hant` 繁体、`zh-Hant-TW` |
| 英语 | `en` | `en-GB`、`en-US` |
| 乌兹别克语 | `uz` | `uz-Latn` 拉丁字母、`uz-Cyrl` 西里尔字母 |
| 俄语 | `ru` | `ru-RU` |
| 波斯语 | `fa` | `fa-IR`；不要误写成国家代码 `ir` |
| 阿拉伯语 | `ar` | `ar-EG`、`ar-SA` |
| 法语 | `fr` | `fr-FR`、`fr-CA` |
| 西班牙语 | `es` | `es-ES`、`es-419` 拉丁美洲 |
| 葡萄牙语 | `pt` | `pt-BR`、`pt-PT` |
| 土耳其语 | `tr` | `tr-TR` |
| 哈萨克语 | `kk` | `kk-Cyrl` |
| 乌尔都语 | `ur` | `ur-PK` |
| 印地语 | `hi` | `hi-IN` |
| 孟加拉语 | `bn` | `bn-BD` |
| 印度尼西亚语 | `id` | 使用 `id`，旧 `in` 已废弃 |
| 马来语 | `ms` | `ms-MY` |
| 泰语 | `th` | `th-TH` |
| 越南语 | `vi` | `vi-VN` |
| 日语 | `ja` | `ja-JP` |
| 韩语 | `ko` | `ko-KR` |

这张短表只列核对示例，不要求作者提供这些翻译，也不表示各地区语言完全相同。只写 `uz` 时应在作者说明中解释所用字母；需要区别两套译文时分别使用 `uz-Latn` 和 `uz-Cyrl`。有两字母 BCP 47 标签的语言不要直接套用 ISO 639-2 的三字母别名，例如这里使用 `ru`、`uz`、`fa`。

## SDK 13 的实际格式

SDK 13 当前接受 BCP 47 的受限形式 `language[-Script][-REGION]`：language 为小写 2–3 字母，Script 为首字母大写的四字母文字系统，REGION 为大写两字母或三位数字。包声明必须规范书写，如 `uz-Cyrl-UZ`；不接受 `uz_CYRL_uz`、扩展、变体或私用标签。本片校验结构，不以正则冒充 IANA 注册有效性校验；未列入短表的官方语言仍可使用。

```json
{
  "localization": {
    "defaultLocale": "uz-Latn",
    "messages": {
      "uz-Latn": { "query.submit": "Qidirish" },
      "ru": { "query.submit": "Поиск" }
    }
  }
}
```

支持语言由 `messages` 的键直接派生，不必重复声明数组。默认语言定义完整词条，其他语言可只翻译其中一部分；缺词条回退到默认语言。调用方式为 `ctx.i18n.t('query.submit')`，`ctx.locale` 是用户请求语言，`ctx.i18n.locale` 是实际采用的包语言。标签选择依次尝试精确匹配、语言加文字系统、基础语言，最后包默认语言；不会把 `zh-Hant` 随意匹配为 `zh-Hans`。

跟随系统时，脚本收到系统原始语言标签，即使核心暂未翻译该语言；用户指定应用语言时使用该选择。语言改变不修改实体 id、时间/数值语义或学校身份。包字典变更纳入 digest、安装更新重新检查；安装和运行不向外部翻译服务发送数据。完整用法见[受信脚本参考](trusted_scripts.md)和 [ADR-070](../adr/adr_070_script_localization.md)。
