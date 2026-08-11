# 声明式数据流 · 逐 op 形式化语义表

> 历史上落实 [V1 ADR-023](../adr/archived/v1/adr_023_declarative_dataflow.md) §5 决策 2 第 4 条「跨端语义逐 op 钉死」。V2 已退役该方向。
> 本文是 **validator 静态签名检查（D8/D9）与两端 runtime 实现的共同事实来源**。
> 落地跟踪见 [`declarative_dataflow_migration.md`](./declarative_dataflow_migration.md)。
>
> 🔒 本文所述语义属安全承重路径（句柄计算 / 密钥使用 / 注入编码）。改动此表 = 改动跨端行为，
> 须同步 validator、两端 runtime 与双跑 golden，并经人工审阅（AGENTS.md §1）。

---

## 0. 类型系统

句柄只有两种类型，**没有数字、没有数组、没有对象**：

| 类型 | 含义 | 产生者 |
|---|---|---|
| `text` | Unicode 文本（UTF-16 码元序列，与 JS/Dart 的 String 同构） | 全部 `bind`、`concat` / `substring` / `base64` / `hex` / `urlencode` / `now`、`args[].text` 字面量 |
| `bytes` | 原始字节序列 | `hmac-sha256` / `hkdf` / `md5` / `sha1` / `sha256` / `aes-cbc`（ADR-028） |

三条结构性后果：

1. **`bind` 的产出恒为 `text`**——三个抽取器（header / body-jsonpath / regex）都读文本。故 `bytes` **只能**由 `hmac-sha256` / `hkdf` / `md5` / `sha1` / `sha256` / `aes-cbc` 产生。
2. **`base64` / `hex` 是唯一的 `bytes → text` 通道**（ADR-023 决策 2 第 1 条）。没有反向的 `text → bytes` 解码 op，`bytes` 的来源因此完全封闭。
3. **`inject` 只接受 `text`**——URL query 与 HTTP 头都是文本面。`bytes` 必须先过 `base64` / `hex`。类型不匹配由 validator **静态**拒绝（D9），不留到运行期。

`text` 作为 `bytes` 位置的输入时（`base64` / `hex` / `hmac-sha256` 的 message）**先按 UTF-8 编码**；这是唯一的隐式转换，两端必须一致。

---

## 1. 签名表

`args` 个数与 `params` 键集合由 validator D8 **精确**强制：缺一个、多一个都是 error。无 `params` 的 op 不得声明 `params`（含空对象）。

| op | args（位置、类型） | params | 输出类型 |
|---|---|---|---|
| `concat` | 2–8 个 `text` | — | `text` |
| `substring` | 1 个 `text` | `start`, `length` | `text` |
| `base64` | 1 个 `text \| bytes` | `variant ∈ {standard, url}` | `text` |
| `hex` | 1 个 `text \| bytes` | `case ∈ {lower, upper}` | `text` |
| `urlencode` | 1 个 `text` | `variant ∈ {component, form}` | `text` |
| `hmac-sha256` | `[0]=key`（🔒 须 `ref`，`text \| bytes`）、`[1]=message`（`text \| bytes`） | — | `bytes` |
| `hkdf` | `[0]=ikm`（🔒 须 `ref`）、`[1]=salt`、`[2]=info`（均 `text \| bytes`） | `length ∈ [1,64]` | `bytes` |
| `now` | 0 个 | `format ∈ {epoch-seconds, epoch-millis, iso8601}` | `text` |
| `md5` | 1 个 `text \| bytes`（message） | — | `bytes`（16） |
| `sha1` | 1 个 `text \| bytes`（message） | — | `bytes`（20） |
| `sha256` | 1 个 `text \| bytes`（message） | — | `bytes`（32） |
| `aes-cbc` | `[0]=key`（🔒 须 `ref`，`text \| bytes`）、`[1]=message`（`text \| bytes`）、`[2]=iv`（`text \| bytes`，字面量或 ref） | `padding ∈ {pkcs7, none}` | `bytes`（密文） |

🔒 **key/ikm 必须是 `ref`，不得是 `text` 字面量**（validator D10）：manifest 是已签名并分发的产物，写入字面量密钥等于公开。适用于 `hmac-sha256` 的 key、`hkdf` 的 ikm、**`aes-cbc` 的 key**。`hkdf` 的 `salt`/`info` 与 `aes-cbc` 的 `iv` 允许字面量（按设计非机密）。

---

## 2. 逐 op 语义与跨端陷阱

每 op 至少一条双端 golden（server TS / client Dart 对同一 fixture 逐字节一致）。

### `concat`
按 args 顺序拼接。空串合法。输出长度受单句柄 64 KB 上限约束——**限额约束输出而非输入**（ADR-023 决策 3）。

### `substring`
`start` / `length` 单位是 **UTF-16 码元**（JS `String.prototype.substring` 与 Dart `String.substring` 的原生单位，两端天然一致；不是字素簇、不是字节）。

🔒 **越界一律 fail-closed，不钳制**：若 `start + length > input.length`，抛错、整条 capability 失败。这刻意**不采用**任何一端的原生行为——JS 会钳制到串尾、Dart 会抛 `RangeError`，二者不一致；统一为「越界即失败」使两端行为定义在我们自己的层，且与决策 6 的 fail-closed 取向一致。实现时**不得**直接透传 `String.substring`。

### `base64`
- `variant: "standard"` = RFC 4648 §4 字母表（`+` `/`），**带 `=` 填充**。
- `variant: "url"` = RFC 4648 §5 base64url 字母表（`-` `_`），**无填充**。

无「换行/分块」变体。`text` 输入先 UTF-8 编码。

### `hex`
定长小写或大写十六进制，无分隔符、无 `0x` 前缀。`case` 必填——不设默认值，避免两端默认值漂移。

### `urlencode`
🔒 两端原生 API 的编码集不一致，故**不得**直接透传（JS `encodeURIComponent` / Dart `Uri.encodeComponent` 的未转义集有差异，`Uri.encodeQueryComponent` 又把空格编成 `+`）。按下表自实现：

| variant | 未转义字符集 | 空格 | 用途 |
|---|---|---|---|
| `component` | `A-Z a-z 0-9 - _ . ~`（RFC 3986 unreserved，**仅此**） | `%20` | URL 组件、签名基串 |
| `form` | 同上 | `+` | `application/x-www-form-urlencoded` |

其余字节一律 `%XX` **大写**十六进制；先 UTF-8 编码再逐字节转义。

> **注入到 `at: url` 会自动做 `component` 编码**（broker 保证 URL 良构）。故**不要**在 url 汇聚点前再加 `urlencode` compute——会双重编码。`urlencode` op 是给**签名基串 / `at: header` 值 / body**（首批未开）这类不经 broker 自动编码的场景用的。

### `hmac-sha256`
标准 HMAC-SHA-256（RFC 2104），输出 32 字节 `bytes`。key 与 message 为 `text` 时按 UTF-8 编码。

### `hkdf`
RFC 5869 HKDF，哈希固定 SHA-256（extract + expand 全流程），输出 `length` 字节。`salt` 允许空串（RFC 5869 规定此时等价于全零 salt——须两端一致，不得省略 extract 步骤）。`length` 上限 64 = 2×HashLen，远低于 RFC 的 255×HashLen，刻意收紧。

### `now`
取值恒等于宿主喂入的 `AdapterRunInput.nowMs`（server `sandbox.ts` / client 对称路径），**不读真实时钟**——现有 smoke 已用固定 `NOW`，双跑因此可复现。

| format | 输出 |
|---|---|
| `epoch-seconds` | `floor(nowMs / 1000)` 的十进制串，无前导零、无符号 |
| `epoch-millis` | `nowMs` 的十进制串 |
| `iso8601` | UTC RFC 3339，**恒带毫秒与 `Z`**：`YYYY-MM-DDTHH:MM:SS.sssZ` |

`nowMs` 为负（1970 前）不在支持范围，运行期 fail-closed。

### `md5` / `sha1` / `sha256`（ADR-028）

标准单向摘要（RFC 1321 / RFC 3174 / FIPS 180-4），输出定长原始 `bytes`（16 / 20 / 32 字节）。message 为 `text` 时按 UTF-8 编码。无参数。产出 `bytes`，注入前须过 `base64` / `hex`。

用途：校本签名基串 `md5(concat(...))` 一类无密钥摘要——区别于 `hmac-sha256`（keyed-MAC）。`md5` / `sha1` 已弱，仅为适配既有校本方案，**不用于任何新的安全用途**。

### `aes-cbc`（ADR-028）

AES-CBC **加密**（只加密，无解密）。输出 `bytes` 密文（16 的倍数），注入前须过 `base64` / `hex`。

🔒 **确定性**：相同 `key + iv + message + padding` 产出唯一密文。IV 由 adapter 声明的字面量或句柄提供，**绝不运行期随机生成**——随机 IV 破双跑 golden，永久排除（§5、ADR-028 §2.4）。

逐端钉死的语义（跨端 golden 必覆盖）：

| 项 | 规则 |
|---|---|
| **key** | **原始密钥字节**，`text` 按 UTF-8。🔒 **绝不**走 OpenSSL `EVP_BytesToKey` / passphrase KDF（crypto-js 对字符串 key 的默认行为）——校本页面几乎都用 `CryptoJS.enc.Utf8.parse(key)` 原始字节模式，adapter 作者须确认站点确为此模式 |
| **变体** | 按 key 字节长度推断：**16→AES-128 / 24→AES-192 / 32→AES-256**；其余长度**运行期 fail-closed**（不新增易漂移的 `variant` param） |
| **iv** | 须**恰 16 字节**，否则 fail-closed；`text` 按 UTF-8 |
| **padding=`pkcs7`** | 标准 PKCS#7；消息为块整数倍时**补整块**（0x10 × 16） |
| **padding=`none`** | 消息长度须为 16 的整数倍，否则 fail-closed；不补填充 |
| **message** | `text` 按 UTF-8；`bytes` 原样 |

驱动证据：西电水电 body（固定 key/iv `1234567812345678`）、密码（key=登录页盐 `bind`、iv 固定 `xidianscriptsxdu`），见 `adapters_tests/XIDIAN/energy/meter.py`、`ids/login.py`。

---

## 3. 抽取器语义（`bind`）

| source | 输入 | 输入上限 | 失败条件（均 fail-closed） |
|---|---|---|---|
| `header` | 脱敏**前**的响应头 | 4 KB | 头不存在 / 出现多次 |
| `body` | 响应体 | 8 MB（对齐 `DEFAULT_MAX_BODY_BYTES`） | 非 JSON / JSONPath 选中 0 个或 >1 个 / 选中值非标量 / **整数超安全范围**（`extract_number_unsafe`） |
| `regex` | 响应体 | 8 KB（**超出即失败，不静默截断**） | 不匹配 / 指定 group 未参与匹配 / 超回溯步数预算 |

- 头名大小写不敏感匹配；值取原始串，不做 trim。
- JSONPath 选中的标量：字符串取原值；数字/布尔按 JSON 规范序列化为文本；`null` 视为失败。
- 🔒 **大整数跨端一致性**：数字为**整数值且 `|n| > 2^53−1`（JS `Number.MAX_SAFE_INTEGER`）时一律 fail-closed（`extract_number_unsafe`）**。因 JS `JSON.parse` 在执行器读到值**之前**就已把超范围整数舍入进 double（精度不可恢复），而 Dart `jsonDecode` 保 64 位精度——若放行则两端静默漂移。故只放行 `|n| ≤ 2^53−1` 的整数（两端逐字节一致）；非整值浮点保持既有序列化（`String(number)` ↔ `_numToText`）。此规则于两端 `scalarToText`/`_scalarToText` 对称实现，golden `body_jsonpath_number_safe_max` / `..._safe_min_negative` / `..._unsafe_fail_closed` 钉死。
- 🔒 抽取在**脱敏前**执行、且**只在 broker 内部**——句柄从不进入 adapter。这正是本 ADR 比命令式更安全之处（命令式下 adapter 必须读 body 才拿得到中间 token）。
- 🔒 `regex` 输入超 8 KB **不截断而是失败**：截断会让行为随响应大小静默改变，属数据依赖的隐式分支。

---

## 4. 限额（两端必须一致）

| 限额 | 值 | 强制方 |
|---|---|---|
| 单句柄值上限 | 🔒 **64 KB** | runtime |
| 全 DAG 句柄总预算 | 🔒 **4 MB** | runtime |
| compute 节点数（bind + compute + inject） | 64 | validator D11 |
| 引用嵌套深度 | 16 | validator D11 |
| 每 op args 个数 | 8 | validator D11 + schema `maxItems` |
| regex 回溯步数预算 | 待 runtime 实现时定值 🔒 | runtime |
| 请求数 | 复用现有 `maxRequests`（默认 20） | runtime |

🔒 **限额必须同时约束输出**：`concat` 可自我倍增（`c1=concat(x,x)`、`c2=concat(c1,c1)`…），仅限输入时嵌套 16 层即 2¹⁶ 倍放大。单句柄 64 KB + 全 DAG 4 MB 是主闸门，深度与节点数只是纵深。

---

## 5. 首批不含的 op（记录，避免反复重提）

| 缺席项 | 理由 |
|---|---|
| `random` / `uuid` | 破 ADR-001 §8 双跑 golden，**永久禁止**（非「首批延后」） |
| 随机 IV AES / RSA-OAEP / RSA-PKCS#1 **加密** | ADR-028 §2.4：填充/IV 随机 → 破双跑 golden，**永久排除**（除非将来设计 broker 定值喂入的 nonce 通道，类比 `now`）。留 WebView / imperative |
| `aes-cbc` **解密** | ADR-028 §5：首批只加密（登录 / 取数是「构造密文发出」）；解密留待真实需求 |
| `sha512` / `aes-ecb` / `des` / `3des` / `rsa-sign-pkcs1` | 确定性、可后补，首批无真实抓包证据；ECB 语义弱不鼓励；RSA 签名需私钥=凭证派生 `ref`，待 ADR-017 §2.8 mint 盲区具体方案一并裁定 |
| 签名方案枚举 id | ADR-017 §2.8：「没有封闭方案枚举之前，不开这道口」——目前无任何具体方案 id 可枚举，且驱动场景已被 `hmac-sha256` + `concat` + ADR-028 摘要覆盖。出现真实案例时按本表格式补入 |
| `text → bytes` 解码 | 会打开 `bytes` 的第二个来源，破坏 §0 的封闭性；无真实需求 |
| `css-select` 抽取器 | ADR-023 决策 1：跨端一致成本最高、DOM 内存在移动端膨胀 10–20 倍；标记可扩展，非否决 |
| `at: "body"` 注入 | `requests[]` 尚无 body 声明面，无可合流的基底；待 body 声明面落地再评 |
| 任意纯计算 | ADR-023 §2.4：预设为复用 QuickJS 的零依赖后续升级，触发条件 = 举出封闭词表无法表达且非命令式的真实案例 |
