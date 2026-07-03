# tools/ohos · OHOS 构建环境与签名工具

Linux 无 DevEco Studio 下，用华为 **Command Line Tools** 完成 OHOS（HarmonyOS）hap 的
**构建 + 后置签名 + 真机安装**的辅助脚本与环境配置。

> 面向：`client/ohos/`（Flutter-OHOS 嵌入）。build/装机的完整流程见
> [`client/ohos/README.md`](../../client/ohos/README.md)；本目录只管**环境隔离**与**签名材料**两件事。
> 边界见 AGENTS.md 红线 #4/#5/#8。
> 关联：[`docs/probes/probe_001_smoke_plan.md`](../../docs/probes/probe_001_smoke_plan.md) · issue #65 · ADR-016 §2.4。

---

## 目录内容

| 文件 | 作用 | 入库? |
|---|---|---|
| `env.sh.example` | OHOS CLI 环境（PATH / SDK / node）模板 | ✅ |
| `sign.debug.env.example` | **debug** 签名材料路径模板 | ✅ |
| `sign.release.env.example` | **release** 签名材料路径模板 | ✅ |
| `build-hap.sh` | `flutter build hap`（ohos fork）+ 后置签名，一步出 signed hap；`--debug`/`--release` 按 mode 自选签名材料 | ✅ |
| `sign-hap.sh` | 只对一个已有 unsigned hap 后置签名（不重编）；`--debug`/`--release` 自选材料 | ✅ |
| `env.sh` | 你本机实际环境（从 `.example` 复制） | ❌ gitignore |
| `sign.debug.env` | 你本机 **debug** 签名材料路径（含私钥库路径，红线 #8） | ❌ gitignore |
| `sign.release.env` | 你本机 **release** 签名材料路径 | ❌ gitignore |

> 兼容：脚本在缺 `sign.<mode>.env` 时回退 legacy `sign.env`（老配置不破）。新配置请用分 mode 的两个文件。

---

## 一次性准备

```bash
# 1) 环境：复制模板，按本机改 OHOS_CLI_HOME（默认 /opt/ohos_cli_tools）
cp tools/ohos/env.sh.example tools/ohos/env.sh

# 2) 签名材料：按需复制模板，填你的 keystore / cert / profile / 密码路径
cp tools/ohos/sign.debug.env.example   tools/ohos/sign.debug.env    && $EDITOR tools/ohos/sign.debug.env
cp tools/ohos/sign.release.env.example tools/ohos/sign.release.env  && $EDITOR tools/ohos/sign.release.env   # 需要出 release 包时才配

# 3) 让 Flutter-OHOS fork 记住 SDK（持久，做一次）
fvm spawn ohos/br_3.27.4-ohos-1.0.4 config --ohos-sdk /opt/ohos_cli_tools/sdk/default/openharmony
```

---

## 环境隔离：只在需要时带进 shell，不污染主 shell

`env.sh` 幂等、只 prepend 一次。两种干净用法：

```bash
# A) 子 shell 包裹（一次性命令，退出即自动"脱掉"）
( source tools/ohos/env.sh && fvm spawn ohos/br_3.27.4-ohos-1.0.4 doctor )

# B) direnv（日常，cd 进 client/ohos 自动加载、cd 出自动卸载）
cp client/ohos/.envrc.example client/ohos/.envrc && direnv allow
```

> **不要**再写"脱环境变量"脚本——可靠还原 PATH 很脆；子 shell / direnv 就是天然卸载。

---

## 构建 + 签名（debug / release 分签）

`build mode` 决定两件事：`flutter build hap` 的编译模式 **+** 用哪套签名材料——**自助选择**，
无需手动指定材料文件：

| 命令 | 编译 | 签名材料 | 产物 |
|---|---|---|---|
| `tools/ohos/build-hap.sh`（默认） | `--debug` | `sign.debug.env` | `entry-default-debug-signed.hap` |
| `tools/ohos/build-hap.sh --release` | `--release` | `sign.release.env` | `entry-default-release-signed.hap` |

```bash
# 一步出 signed hap（build + sign）——默认 debug
tools/ohos/build-hap.sh

# release 包
tools/ohos/build-hap.sh --release

# 透传其余 flutter 参数（如探针门禁）
tools/ohos/build-hap.sh --debug --dart-define=OHOS_PROBE=true

# 只重新签名一个已有 unsigned hap（不重编）——同样按 mode 自选材料
tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap>            # debug
tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap> --release  # release
```

debug 与 release 产物**按 mode 命名、互不覆盖**，可并存。`sign-hap.sh` 走
`hap-sign-tool.jar sign-app -mode localSign`，签完自动 `verify-app`（应报 `Verify success`）。
装真机见 [`client/ohos/README.md` §2](../../client/ohos/README.md)。

---

## profile 更新后：重签 vs 重编（决策）

profile（`.p7b`）是**签名期**嵌入 hap 签名块的，**不进编译产物**。所以：

| 变了什么 | 要做什么 |
|---|---|
| 换真机（新 UDID）、证书续期、换 profile —— **bundle id 不变** | **只重签**：改 `sign.<mode>.env` 里的 `SIGN_PROFILE` 路径 → 对已有 unsigned hap 跑 `sign-hap.sh`（秒级，不重编） |
| profile 的 **bundle id 变了** | **先改再重编**：改 [`AppScope/app.json5`](../../client/ohos/AppScope/app.json5) 的 `bundleName` 为新 bundle id → `build-hap.sh` 重编（bundle id 编进 hap，单独重签会 install 失败） |
| 改了代码 / 依赖 | `build-hap.sh` 重编（build + 自动重签） |

> debug profile 锁本机平板 UDID（`hdc shell bm get --udid`），换平板须在 AGC 用新 UDID 重签发 `.p7b`——属上表第一行「只重签」。

---

## 签名材料（`sign.<mode>.env` 字段）

机器+账号相关私密物，经 `sign.debug.env` / `sign.release.env`（均 gitignored）注入，
**绝不入库**（红线 #8）。两文件字段同名、按 mode 各填一套：

| 变量 | 含义 |
|---|---|
| `SIGN_KEYSTORE` | 私钥库 `.p12`（PKCS12）。查别名：`keytool -list -keystore <p12> -storetype PKCS12` |
| `SIGN_KEY_ALIAS` | 库内密钥别名 |
| `SIGN_APP_CERT` | 应用签名证书 `.cer`（AGC 用你的 CSR 签发） |
| `SIGN_PROFILE` | profile `.p7b`；**debug 版锁本机平板 UDID**（`hdc shell bm get --udid`），换平板须在 AGC 重签；release 版不锁 UDID |
| `SIGN_PWD_FILE` | 单行密码文件（keystore 与 key 同口令时复用） |
| `SIGN_ALG` | 签名算法；EC 密钥用 `SHA256withECDSA` |

**换 profile/证书只改对应 `sign.<mode>.env`，不动脚本**；若 profile 的 bundle id 变了，
按上节决策表：同步 [`client/ohos/AppScope/app.json5`](../../client/ohos/AppScope/app.json5)
的 `bundleName` 并重编。

---

## Docker（backlog，暂不做）

探针阶段的 go/no-go 是**真机 + 用户手解滑块**的交互测试，塞不进 headless 容器，Docker 现在收益≈0。**该上的时机**：有了**非交互 `hvigorw assembleHap`** 且值得可复现进 CI/release 时。**前置**：先确认华为 DevEco/OpenHarmony SDK 的 **EULA 是否允许打进镜像 / 再分发**（红线 #9 许可证）——否则只能"本地构建镜像、不发布"。

