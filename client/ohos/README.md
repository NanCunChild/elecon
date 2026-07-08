# client/ohos · HarmonyOS（鸿蒙）平台嵌入

Flutter 客户端的 **OHOS（HarmonyOS NEXT / OpenHarmony）平台目录**，由 Flutter-OHOS fork 的
`flutter create --platforms ohos` 生成。当前为 **Probe-001 阶段一（工具链冒烟）** 的底座 ——
仅平台 scaffold + 已验证可 build/签名，**尚未承载真实业务 UI**。

> 关联：[`docs/probes/probe_001_smoke_plan.md`](../../docs/probes/probe_001_smoke_plan.md) ·
> [`docs/adr/adr_016_complex_login.md`](../../docs/adr/adr_016_complex_login.md) §2.4 · issue #65 ·
> 构建环境与签名脚本见 [`tools/ohos/README.md`](../../tools/ohos/README.md)。

---

## 0. 为什么是独立目录 + 独立 SDK

- **Flutter 版本分叉**：主线/CI 锁 **官方 3.44.1**；OHOS 只能用 OpenHarmony-SIG 的 Flutter-OHOS
  fork（当前 `ohos/br_3.27.4-ohos-1.0.4` = 3.27.5-ohos-1.0.4，Dart 3.6.2）。官方 3.44.1
  **build 不了 OHOS**，两条 SDK 经 **FVM 并存、互不污染**：平时主线用官方版保持纯净，仅打/跑 OHOS 时
  切 ohos fork。
- **OHOS 不进主线 CI**：分叉 SDK 跑不了官方 `flutter test`；OHOS 验收是**真机手动门**（凭证无关的
  S1–S4 冒烟，见 smoke plan），证据留档、不做自动闸门。
- `ohos/` 下无 Dart 业务码，OHOS 专用 Dart 入口在 `ohos_probe/`，并由 `analysis_options.yaml`
  从主线官方 stable 分析中排除；官方 stable 的 Android/iOS/桌面 `flutter analyze/test` 不解析
  `flutter_inappwebview_ohos`。
- OHOS 专用依赖只写入 `pubspec.ohos.yaml`。`tools/ohos/build-hap.sh` 构建期间临时覆盖
  `pubspec.yaml`/`pubspec.lock`，退出时恢复，避免污染主线 lockfile。

---

## 1. 工具链：Linux 无 DevEco Studio 也能编

DevEco Studio（EcoIDE）只有 Windows/Mac；Linux 用华为 **Command Line Tools**（本仓默认装在
`/opt/ohos_cli_tools`，linux-x64 6.1.1.280：hvigor 6.24.2 / ohpm 6.1.2.268 / HarmonyOS SDK
6.1.1 · API 24 / hdc / 内置 node）。**它能完成 build + 签名 + 真机安装的全链路**，IDE 的
GUI 预览器 / 自动签名在真机调试里都用不上。

环境隔离与签名材料配置见 [`tools/ohos/README.md`](../../tools/ohos/README.md)。一次性准备：

```bash
# 让 Flutter-OHOS fork 记住 SDK（持久，做一次）
fvm spawn ohos/br_3.27.4-ohos-1.0.4 config --ohos-sdk /opt/ohos_cli_tools/sdk/default/openharmony
# 自检（HarmonyOS toolchain 应变 ✓）
( source tools/ohos/env.sh && fvm spawn ohos/br_3.27.4-ohos-1.0.4 doctor )
```

---

## 2. 构建 + 签名 + 装真机

HarmonyOS NEXT 要求**签名的 hap（debug 亦然）**。无 IDE 时走**后置签名**：`flutter build hap` 出
unsigned → `hap-sign-tool` 签名。仓库脚本已封好（在仓库根目录跑）：

```bash
tools/ohos/build-hap.sh                                      # flutter build hap --debug + 签名
tools/ohos/build-hap.sh --release                            # release 包（用 release 签名材料，见下）
tools/ohos/build-hap.sh --debug --dart-define=OHOS_PROBE=true # Probe-001 入口
# 产物：client/ohos/entry/build/default/outputs/default/entry-default-<mode>-signed.hap
```

签名材料按 build mode **自助选择**（debug→`sign.debug.env`，release→`sign.release.env`），
细节见 [`tools/ohos/README.md`](../../tools/ohos/README.md)。装到真机（平板 USB 连好、
`hdc list targets` 能看到）：

```bash
( source tools/ohos/env.sh && \
  hdc install -r client/ohos/entry/build/default/outputs/default/entry-default-debug-signed.hap )
```

> 该路径已实测跑通：scaffold → `flutter build hap` 出 unsigned hap →
> `sign-hap.sh` → `verify-app` 报 `Verify success`。

### 日常：换 profile / 重新签名 / 出新构建

profile 是**签名期**嵌入的、不进编译产物，故按「变了什么」决定重签还是重编：

- **换签名 profile / 证书（bundle id 不变）** → **只重签，不重编**：改
  `tools/ohos/sign.<mode>.env`（gitignored）里的路径（`SIGN_PROFILE` / `SIGN_APP_CERT` /
  `SIGN_KEYSTORE` / `SIGN_KEY_ALIAS` / `SIGN_PWD_FILE`；查别名
  `keytool -list -keystore <p12> -storetype PKCS12`），再对已有 unsigned hap 重跑：
  ```bash
  tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap>            # debug
  tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap> --release  # release
  ```
  换真机（新 UDID）即属此列——在 AGC 用新 UDID 重签发 `.p7b`、改路径、重签即可。
- **profile 的 bundle id 变了** → **先改再重编**：同步 §3-1 的 `bundleName` 后走 `build-hap.sh`
  （bundle id 编进 hap，单独重签会 install 失败）。
- **改了 Dart / 资源 / 依赖** → 重编：
  ```bash
  ( cd client && fvm spawn ohos/br_3.27.4-ohos-1.0.4 clean )   # 可选：彻底重编
  tools/ohos/build-hap.sh                                       # build + sign
  hdc install -r client/ohos/entry/build/default/outputs/default/entry-default-debug-signed.hap  # -r 覆盖安装
  ```
- **验证签名**：`java -jar /opt/ohos_cli_tools/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar
  verify-app -inFile <signed.hap> -outCertChain /tmp/c.cer -outProfile /tmp/p.p7b`（应报 `Verify success`）。

---

## 3. 真机调试前必改的 4 处（scaffold 占位 / 设备绑定）

卡点通常不在工具链，而在签名材料与 scaffold 占位的对齐：

1. **`bundleName`**（[`AppScope/app.json5`](AppScope/app.json5)）现为占位 `com.example.elecon` ——
   必须改成你**调试 profile（`.p7b`）签发时使用的 bundle id**，否则签名/安装失败。
2. **debug `.p7b` 必须含本机平板的 UDID**（调试 profile 锁设备）：在 AppGallery Connect 登记。
   取 UDID：`hdc shell bm get --udid`。
3. **`deviceTypes`**（[`entry/src/main/module.json5`](entry/src/main/module.json5)）现仅 `"phone"` ——
   平板须加 `"tablet"`，否则平板可能拒装。
4. **API 对齐**：SDK = API 24，`build-profile.json5` 的 `compatibleSdkVersion = 5.0.0(12)` 为下限
   （NEXT 平板均满足）；确认平板系统版本 ≥ 该下限。

签名材料（keystore / 证书 / profile / 密码）是机器+账号相关私密物，经
`tools/ohos/sign.debug.env` / `sign.release.env`（均 gitignored）配置，**绝不入库**（红线 #8 精神）。

---

## 4. 边界（红线）

- 本目录服务 **Probe-001 阶段一冒烟（凭证无关）**：不碰 CAS 登录、不收割 session、不落盘任何
  JSESSIONID 级凭证。
- 完整探针（② `navigationAllow` 闭锁 + ③ incognito 隔离/残留时序的真机验收，标的 XIDIAN IDS CAS）
  触**红线 #1**，须**人工主导 + 安全清单 + ≥1 人工审，AI 不得独自闭环**（AGENTS.md §1）。
- WebView 收割路径属 debug-only/探针，**编译期从 release 剔除**（同红线 #4/#5）。
