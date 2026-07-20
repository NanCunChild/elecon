# HelloWorld 通路测试 adapter

此 adapter 仅用于验证端点 D → 客户端接收 → 验签 → 加载 → QuickJS 执行 → 日志/产出显示的链路。

- `official` + `fetch` 模式
- 不访问网络（manifest 中的 `.invalid` allow 项仅满足 fetch 契约，不会被 capability 使用）
- 不声明或读取凭证
- capability：`app.announcement`
- 日志：`HelloWorld`
- 产出：`elecon.app.announcement`，内容为 `HelloWorld`

必须通过正式 YubiKey 签名后才能被客户端 official loader 接受。
