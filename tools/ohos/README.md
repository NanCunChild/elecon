# tools/ohos · OHOS 构建环境与签名工具

Linux 无 DevEco Studio 下，用华为 **Command Line Tools** 完成 OHOS（HarmonyOS）hap 的
**构建 + 后置签名 + 真机安装**的辅助脚本与环境配置。

> 面向：`client/ohos/`（Flutter-OHOS 嵌入）。build/装机的完整流程见
> [`client/ohos/README.md`](../../client/ohos/README.md)；本目录只管**环境隔离**与**签名材料**两件事。
> 边界见 AGENTS.md 红线 #4/#5/#8。

---

## 目录内容

| 文件 | 作用 | 入库? |
|---|---|---|
| `env.sh.example` | OHOS CLI 环境（PATH / SDK / node）模板 | ✅ |
| `sign.env.example` | 签名材料路径模板 | ✅ |
| `build-hap.sh` | `flutter build hap --debug`（ohos fork）+ 后置签名，一步出 signed hap | ✅ |
| `sign-hap.sh` | 只对一个已有 unsigned hap 后置签名（不重编） | ✅ |
| `env.sh` | 你本机实际环境（从 `.example` 复制） | ❌ gitignore |
| `sign.env` | 你本机实际签名材料路径（含私钥库路径，红线 #8） | ❌ gitignore |

---

## 一次性准备

```bash
# 1) 环境：复制模板，按本机改 OHOS_CLI_HOME（默认 /opt/ohos_cli_tools）
cp tools/ohos/env.sh.example tools/ohos/env.sh

# 2) 签名材料：复制模板，填你的 keystore / cert / profile / 密码路径
cp tools/ohos/sign.env.example tools/ohos/sign.env
$EDITOR tools/ohos/sign.env

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

## 构建 + 签名

```bash
# 一步出 signed debug hap（build + sign）
tools/ohos/build-hap.sh
# 产物：client/ohos/entry/build/default/outputs/default/entry-default-signed.hap

# 只重新签名一个已有 unsigned hap（不重编）
tools/ohos/sign-hap.sh <path/to/entry-default-unsigned.hap>
```

`sign-hap.sh` 走 `hap-sign-tool.jar sign-app -mode localSign`，签完自动 `verify-app`
（应报 `Verify success`）。装真机见
[`client/ohos/README.md` §2](../../client/ohos/README.md)。

---

## 签名材料（`sign.env` 字段）

机器+账号相关私密物，经 `sign.env`（gitignored）注入，**绝不入库**（红线 #8）。字段：

| 变量 | 含义 |
|---|---|
| `SIGN_KEYSTORE` | 私钥库 `.p12`（PKCS12）。查别名：`keytool -list -keystore <p12> -storetype PKCS12` |
| `SIGN_KEY_ALIAS` | 库内密钥别名 |
| `SIGN_APP_CERT` | 应用签名证书 `.cer`（AGC 用你的 CSR 签发） |
| `SIGN_PROFILE` | profile `.p7b`；**debug 版锁本机平板 UDID**（`hdc shell bm get --udid`），换平板须在 AGC 重签 |
| `SIGN_PWD_FILE` | 单行密码文件（keystore 与 key 同口令时复用） |
| `SIGN_ALG` | 签名算法；EC 密钥用 `SHA256withECDSA` |

**换 profile/证书只改 `sign.env`，不动脚本**；若 profile 的 bundle id 变了，同步
[`client/ohos/AppScope/app.json5`](../../client/ohos/AppScope/app.json5) 的 `bundleName`。
