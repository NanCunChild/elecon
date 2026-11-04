# 包内多语言示例

SDK13，虚构学校，不联网、不读取凭据。作者选择土耳其语 `tr` 与乌兹别克语 `uz`，说明脚本不受核心界面语言列表限制。语言资源是 manifest.localization 的一部分，安装时随包校验并受 digest 授权。

```sh
npm run scripts:package -w tools -- \
  --manifest adapters/_template/trusted/localized/manifest.json \
  --source adapters/_template/trusted/localized/index.js \
  --out /tmp/school-localized-example.elecon.json
```

`ctx.locale` 是请求语言，`ctx.i18n.locale` 是协商后的包语言。未适配的语言回退 `tr`；新增语言只需作者在 messages 添加字典并更新包版本，缺少的条目回退默认语言。`{name}` 参数必须在各翻译中一致。官方代码与标签规则见[语言代码参考](../../../../docs/reference/script_language_codes.md)，完整用法见[受信脚本参考](../../../../docs/reference/trusted_scripts.md)。此示例不代表完整学校接入或母语审校。
