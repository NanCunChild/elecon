# ADR-005：Manifest V2、`.eleb` 与开发模型

- **状态**：已接受（Accepted）
- **日期**：2026-08-11
- **依赖**：[ADR-002](./adr_002_execution_trust.md)、[ADR-003](./adr_003_core_security_boundary.md)、[ADR-004](./adr_004_credential_store.md)、[ADR-010](./adr_010_signer_identity.md)

## 1. 单一 adapter 形态

V2 只保留普通异步 JavaScript capability handler。删除 declarative/imperative 双 requestGraph、`requests/bind/compute/inject`、opaque handle、dataflow crypto op 和 mandatory Response Masker。

adapter 作者使用接近 server-side JavaScript/爬虫的流程：

```js
export const capabilities = {
  async "grades.list"(ctx, params) {
    const credentials = await ctx.credentials.list({ systemId: "dean" });
    const response = await ctx.fetch(buildUrl(params), buildRequest(credentials));
    return normalize(await response.json());
  },
};
```

## 2. `.eleb` 分发单元

`.eleb`（Elecon Bundle）是单 adapter、自包含、可直接验证的分发与执行信任单元。一个 `.eleb` 只有：

- 一个 canonical manifest；
- 一个 canonical `adapterId`；
- 一个 signer identity 或过渡期 unsigned 标记；
- 一种执行载荷形态；
- 一组被 canonical bundle digest 完整覆盖的文件和元数据。

内部可以包含多个 module 和 capability，但不创建多个 adapter identity、安装记录或 Credential namespace。多个 adapter 必须分成多个 `.eleb`。

`.eleb` 自身包含 manifest、载荷、digest algorithm ID、signature envelope 和执行所需的兼容信息。loader 不依赖 runtime catalog 闭合 adapterId、version 或 digest；official/local 身份直接由 `.eleb` 签名与本机 trust state 裁定。

官方商店、网站或 CDN 可以发布普通静态发现索引，提供列表、搜索、下载 URL 和更新提示。发现索引不是信任根，不参与执行准入；被篡改的索引最多诱导下载错误文件，不能把 non-official `.eleb` 变成 official。

独立 official revocation 继续保留，由 ADR-006 治理。

### 2.1 Deterministic ZIP

`.eleb` 首版物理容器是 deterministic ZIP，但 canonical execution content digest 不直接 hash ZIP 原始字节。digest 按规范化 entry path、role、encoding、长度和解压后 bytes 计算，因此不同压缩器产生的等价容器可以具有同一 execution identity。

打包器必须固定 entry 排序、UTF-8 path、时间戳、压缩方法、deflate 参数、权限和额外字段。首版只允许 ZIP method 0（stored）和 8（deflate），拒绝 Zip64、Zstandard、传统/AES 加密和未知 extra field。loader 在分配或执行前强制：

- packed 总计最多 64 MiB；
- unpacked 总计最多 256 MiB；
- 最多 256 entries；
- 单 entry unpacked 最多 128 MiB；
- entry path 最多 256 UTF-8 bytes；
- 总压缩比最多 20x；
- 拒绝重复或 canonical 后重名 path；
- 拒绝绝对路径、`..`、反斜线、NUL、symlink、hardlink、device、encrypted entry 和结构/data-descriptor 歧义。

bounded unpack 只产出不可执行候选；通过 ADR-002/010 trust gate 前不得 evaluate source 或 load bytecode。

### 2.2 固定布局

首版只接受以下布局：

```text
manifest.json
payload/source/**                 # source 形态
payload/bytecode/<quickjs-abi>.qbc # bytecode-only 形态
resources/**
META-INF/signature.json          # signed 形态恰好一个；过渡 unsigned 缺失
```

source 与 bytecode 目录互斥。未知 executable path、重复 ABI variant、manifest 未闭合的 entry 或从一个角色伪装为另一个角色均拒绝。

首版 manifest 使用 `manifestVersion: "2.0"`，并以 `payload.kind` 区分 `source` 与
`bytecode-only`。manifest 的 `files` 是除 detached signature 外所有 entry 的闭合清单；每项固定
`path`、`role` 和 `encoding`，loader 必须要求清单与 ZIP 中实际 entry 精确相等。source 使用
`payload.entry` 指向 `payload/source/**`；bytecode-only 使用 `payload.variants` 将 ABI ID 映射到
`payload/bytecode/<abi>.qbc`。第一版 contract schema 位于 `contract/eleb/`。

`manifest.json` 和 `META-INF/signature.json` 使用 RFC 8785 JCS 的受限子集：UTF-8、无 BOM、拒绝重复键和 lone surrogate；manifest 禁止浮点，整数限制在跨 TS/Dart 安全范围。canonical digest 和签名使用规范化结果，不使用作者提交的空白或键序。

## 3. Manifest V2

manifest 只声明静态、可审查和可由宿主强制的事实：

- canonical lowercase 反向域名 `adapterId`、version、entry；
- 最低兼容 Elecon App version；
- capabilities、params 与 emits schema；
- network scheme/origin/path/method；
- 跨 Credential Store namespace 的 exact target adapterId 与 `read`、`write`、`delete` 模式；
- 宿主 WebView 登录计划；
- 资源预算和必要静态元数据；
- 执行载荷形态；bytecode-only 额外声明其 Elecon QuickJS ABI variant IDs。

manifest 不自报 official 或用户信任。签名 envelope 决定 signer identity，宿主 trust state 决定执行路径。网络与 Credential 声明是宿主强制上限，不是防止受信 adapter 外泄数据的证明。

## 4. 执行载荷

一个 `.eleb` 的执行载荷必须在以下两种形态中二选一，不能同时包含并由运行时择优：

1. **source**：携带 digest 覆盖的 JavaScript source modules。客户端在安装或首次运行时使用自己支持的 QuickJS ABI 本地编译，并缓存 bytecode。
2. **bytecode-only**：不携带公开 source，携带一个或多个按 Elecon QuickJS ABI ID 索引的 bytecode variants。

source manifest 不声明 ABI ID，由满足最低 App version 的客户端使用当前内置 QuickJS 编译；ABI ID 不表示语言 feature floor，也不可比较大小。bytecode-only 同时声明最低 App version 和 exact ABI variants：前者约束 host API/capability，后者约束 bytecode loader。

source 本地编译缓存不是 `.eleb` 权威内容，不改变 bundle digest。缓存必须绑定原 `.eleb` digest、QuickJS ABI ID 和编译配置；不匹配或损坏时丢弃重建。

source 使用标准 ESM。import resolver 只接受 `./`、`../` 在 `payload/source/**` 内 canonical resolve，以及版本化固定 `elecon:*` 宿主模块；禁止 bare package specifier、Node resolution、`node_modules`、文件系统和 remote import。dynamic import 的计算结果也必须命中 digest 覆盖的现有 bundle module。构建工具负责将第三方依赖预打包并改写为 bundle 内相对 import。

bytecode-only 只提高逆向成本，不提供加密、DRM 或“代码不可提取”的安全保证。客户端没有匹配 ABI variant 时 fail closed，不下载远程代码、不猜测兼容性，也不回退到不存在的 source。

第三方 local signed 可以分发 bytecode-only `.eleb`。首次 signer 风险页必须显著标记客户端无法进行源码级静态检查；后续仍按 ADR-010 signer 连续性更新，不因此逐 digest 重新确认。

official bytecode-only 在公开 `.eleb` 中可以不包含源码，但发布前必须向 official 审核方提供对应源码。源码不要求公开。审核方必须覆盖所有发布 ABI variants；不得只审源码后声称 variants 已被可复现证明。

## 5. Elecon QuickJS ABI ID

QuickJS bytecode 兼容性不跟随客户端版本，而跟随 Elecon 管理的精确 QuickJS runtime ABI ID，例如 `elecon-qjs-1`。每个 ABI ID 必须绑定：

- exact upstream QuickJS commit；
- Elecon 补丁集；
- bytecode serializer/loader format；
- 影响字节码解释的 feature flags、编译选项和数据模型；
- 跨平台 bytecode compatibility vectors。

客户端声明自己支持的 ABI ID 集合；`.eleb` bytecode variants 只按 ABI ID 索引，不增加隐藏的 platform 或 architecture 维度。相同 ABI ID 必须表示同一 bytecode 可在所有声明支持该 ID 的平台执行；若平台、架构、字长、endianness 或编译配置不兼容，必须分配不同 ABI ID。

bytecode-only `.eleb` 可以携带多个 ABI variants。canonical bundle digest 覆盖全部 ABI 映射、variant bytes 和 variant digest；任一 variant 变化都产生新 bundle identity。

签名整个 `.eleb` 即为 variants 的完整性和发布者声明，不要求多个 variants 可复现地来自同一源码，也不保证逻辑一致。official 审核必须分别审查或行为验证各 variant；local 用户不得把“同一 bundle”理解为“所有 ABI 执行完全相同逻辑”。

客户端 App version 仍用于宿主 API、UI capability 和整体最低兼容门，但不得用 App version 代替 bytecode ABI ID。

ABI registry 至少发布 ID、upstream commit、Elecon patch digest、编译配置、serializer 标识、支持平台和 compatibility vector digest。ABI ID 一旦发布不得改变含义；不兼容变化分配新 ID。

## 6. SDK

V2 SDK 提供 Web-compatible `ctx.fetch`、Node/爬虫式 raw multi-value `Set-Cookie` 读取、Credential Store namespace API、受控日志、确定性时间/取消信号和宿主登录请求。宿主不提供 fetch cookie jar；adapter 自行管理 cookie 并显式持久化。adapter 不获得 UI、WebView 对象、transport 选择权或 native module。

`adapterId` 使用 canonical lowercase 反向域名格式，作用类似 Android application ID。Credential API 不接受 adapter 提供的 `profileId`：宿主从 invocation 注入当前 profile；self namespace 也不要求传 adapterId，跨 namespace target 只能引用 manifest 中精确声明的 adapterId。adapter 只提供当前 namespace 内的 `systemId`、`credentialName` 和 value。

bundle resources 通过 `ctx.resources.text(path)` 和 `ctx.resources.bytes(path)` 只读访问。path 只能命中 digest 覆盖的 `resources/**`，不暴露宿主文件路径、目录遍历或任意文件 API。默认每 invocation 单资源最多 8 MiB、累计 16 MiB；manifest 可申请到单资源 32 MiB、累计 64 MiB 的绝对硬上限。预算在解压、文本解码和跨 isolate 复制前检查，并独立计入 QuickJS heap。

## 7. Canonical digest 与签名

`.eleb` 必须确定性打包。canonical content digest 首版只使用 SHA-256，algorithm ID 固定为版本化 `sha256-v1`；未知算法、协商或回退均拒绝。digest 至少覆盖 format、manifest、规范化路径、role、encoding、长度、source 或全部 bytecode variants、ABI 映射、资源和实际执行 entry；detached signature 自身不进入 content digest。

signature 固定存于 ZIP 内 `META-INF/signature.json`，是 detached entry，不进入 canonical content digest。所有 signed 包都内嵌 RFC 8032 32-byte raw Ed25519 public key，使 local `.eleb` 可自包含验签；official loader 仍必须要求该 key fingerprint 命中客户端 official trust roots。签名输入使用明确 domain separation，覆盖 `.eleb` format、digest algorithm ID、canonical content digest、signer fingerprint 和防止 signer/algorithm substitution 所需字段。

首版 signed `.eleb` 恰好包含一个 Ed25519 signature；过渡 unsigned 不包含 signature entry。signer fingerprint 是 `SHA-256` over RFC 8032 32-byte raw public key，以 64-char lowercase hex 编码；`keyId` 仅作显示。未知算法、多签、空签名、重复 signature entry 或格式回退均拒绝。official identity 只由客户端 official trust roots 裁定；相同 Ed25519 算法或 signer 自报名不能产生 official 身份。

删除 detached signature 不改变 content digest，但只能在 ADR-002 的 unsigned 迁移窗口内形成可执行候选；unsigned 退役后所有构建都拒绝无 signature `.eleb`。

official、local signer trust、安装缓存和 active binding 都指向同一 canonical execution content digest，而不是 ZIP 容器的偶然序列化字节。

首版 `sha256-v1` 的输入固定为 ASCII `elecon-eleb-content\0v1\0`，随后按 UTF-8 path
字节序排序，对每个非 signature entry 依次追加：u32 big-endian path byte length、path bytes、
u8 role（manifest=1、source=2、bytecode=3、resource=4）、u8 encoding（jcs=1、utf8=2、
binary=3）、u64 big-endian 解码后 content length 和 content bytes，最后对完整输入做 SHA-256。
`manifest.json` 使用受限 JCS bytes；signature entry 不进入 content digest。签名输入固定为 ASCII
`elecon-eleb-signature\0v1\0`，加上三个 u32 big-endian 长度前缀字符串（signature format、
algorithm、digest algorithm）、raw 32-byte content digest 和 raw 32-byte signer fingerprint。
实现与 golden 位于 `tools/src/eleb/`、`client/lib/core/loader/eleb.dart` 和
`contract/golden/eleb/`。

## 8. 开发与审核责任

- fixture 必须脱敏；认证测试使用合成值或测试账号。
- 作者准确声明网络、跨 namespace、凭证、日志和持久化行为。
- source policy 可限制 dynamic import、`eval`、隐蔽资源和超大 bundle，以提高可审性，但不伪装成恶意代码证明。
- bytecode-only 作者接受较弱的客户端静态可审查性；official reviewer 仍取得源码并覆盖每个 variant。
- 统一 template、类型、本机开发 signer、打包和 replay 工具，避免 unsigned 开发 bypass。

## 9. 迁移

1. 固定 `.eleb` schema、canonical digest、signer envelope 和 QuickJS ABI vectors；
2. 落地 official/local signed/过渡 unsigned 三路径和 artifact gates；
3. 提供本机开发 signer、第三方签名工具与 signer 首次确认 UI；
4. 将现有 source adapter 转为 `.eleb`，按需增加 bytecode-only 发布；
5. signed local 全链路成为 required checks 后保留一个稳定版本 unsigned deprecated 窗口；
6. 下一稳定版本删除所有 unsigned grant、导入和执行路径；
7. V2 gates 阻塞通过后删除 V1 contract/runtime、runtime catalog 依赖和旧 bundle envelope，不长期维护双栈。
