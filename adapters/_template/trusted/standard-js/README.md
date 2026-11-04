# SDK17 普通 JavaScript 模板

使用 ES 模块、全局 `fetch`、`Request` 和 `Headers`；仅宿主专有功能放在 `elecon`。辅助函数不需要注册。此模板只读取公开通知，不获取凭据、不自动重试或预加载；数据经 `notice.list/1.1` 交给原生卡片。

`school.example` 和返回数据结构均为合成示例。接入时修改声明域名、请求地址与学校字段转换，再提升包版本并安装批准。不得把示例接口当作实际学校服务。

从仓库根目录打包：

```sh
npm run scripts:package -w tools -- --manifest adapters/_template/trusted/standard-js/manifest.json --source adapters/_template/trusted/standard-js/index.js --out /tmp/standard-js.elecon.json
```

运行接口是有界缓冲子集：无 URL 构造器、流、Blob/FormData、浏览器 Cookie/CORS 模拟；不支持的请求选项明确失败。`AbortSignal` 可停止本地等待，不撤回已发出的操作。旧 `ctx.fetch` 保持原语义；不需要修改旧包即可继续运行。

类型入口：[sdk17.d.ts](../../../../contract/script-sdk/sdk17.d.ts)（使用 ES2022 lib，不混入完整 DOM 类型）。`elecon.errors.create("notices_unavailable")` 返回普通 Error，带固定 `code=script_business_error` 与包限定 `businessCode`；这些字段不代表允许重试。
