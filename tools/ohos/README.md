# tools/ohos · HarmonyOS 构建环境

OHOS（鸿蒙）构建依赖华为 **Command Line Tools**（`ohpm` / `hvigorw` / SDK / `hdc`），其环境变量与 PATH 较"脏"。这里给一套**只在需要时加载、用完自动消失**的隔离方案——不污染主 shell，也不需要"脱环境变量"脚本。

> 关联：[`docs/probes/probe_001_smoke_plan.md`](../../docs/probes/probe_001_smoke_plan.md) · issue #65 · ADR-016 §2.4。

## 一次性准备

1. 装华为 Command Line Tools（含 HarmonyOS SDK），记下安装根（本仓默认 `/opt/ohos_cli_tools`）。
2. 复制 `env.sh.example` → `env.sh`（已 gitignore），改 `OHOS_CLI_HOME` 为你的路径。
3. 让 Flutter-OHOS fork 记住 SDK（持久，做一次）：
   ```bash
   fvm spawn ohos/<your-ohos-version> config --ohos-sdk /opt/ohos_cli_tools/sdk/default/openharmony
   ```
4. 验证：
   ```bash
   ( source tools/ohos/env.sh && fvm spawn ohos/<your-ohos-version> doctor )
   # HarmonyOS toolchain 应变 ✓（ohpm/hvigorw/SDK 就位）
   ```

## 日常用法（二选一）

- **子 shell 包裹**（一次性命令，退出即自动卸载）：
  ```bash
  ( source tools/ohos/env.sh && fvm spawn ohos/<ver> <flutter-args> )
  ```
- **direnv**（自动加载/卸载）：把 `client/ohos/.envrc.example` 复制为 `client/ohos/.envrc`，`direnv allow` 一次；以后 `cd client/ohos` 自动进环境、`cd` 出自动退。

## 为什么不写"脱环境变量"脚本

可靠地还原 `PATH`（去掉刚加的、保留其余、处理重复）很脆，半失败就留下脏状态。**子 shell / direnv 提供天然、可靠的卸载边界**——这才是正确模型。`env.sh` 同时做了幂等 prepend，重复 source 不会把 PATH 越堆越长。

## Docker（backlog，暂不做）

探针阶段的 go/no-go 是**真机 + 用户手解滑块**的交互测试，塞不进 headless 容器，Docker 现在收益≈0。**该上的时机**：有了**非交互 `hvigorw assembleHap`** 且值得可复现进 CI/release 时。**前置**：先确认华为 DevEco/OpenHarmony SDK 的 **EULA 是否允许打进镜像 / 再分发**（红线 #9 许可证）——否则只能"本地构建镜像、不发布"。
