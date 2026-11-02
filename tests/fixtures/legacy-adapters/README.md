# V1 执行器共享测试资产

此目录由 `adapters/_template/{declarative,imperative}` 与 `adapters/_canary` 整理而来。它们是合成/脱敏回归输入，不再作为新学校开发模板。历史模型说明见各子目录；新学校开发入口为[受信脚本](../../../docs/reference/trusted_scripts.md)。

| 资产 | 验证对象 |
|---|---|
| `declarative` | V1 requestGraph、Broker 数据流与成绩归一化 |
| `imperative` | V1 受限 fetch 与成绩归一化 |
| `canary` | Node QuickJS-wasm 与客户端 QuickJS 的共同引擎行为 |

Node 测试直接加载这些源码；客户端 `test/legacy/dual_run_test.dart` 读取同一份源码和 golden。断言与原始业务输入不因移动而改变。Biome 和 PII 扫描继续覆盖本目录；文件不进入 app assets、生产服务构建或模板镜像。

```bash
npm run smoke:sandbox -w server
npx tsx server/src/runtime/adapters-template.replay.smoke.ts
cd client
bash tool/flutter_test.sh fvm flutter test test/legacy/dual_run_test.dart
```
