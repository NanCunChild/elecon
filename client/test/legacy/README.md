# V1 执行路径回归

这里集中验证仍被客户端使用的 V1 签名加载、Broker/Masker、requestGraph、旧学校 manifest 与登录桥接。目录隔离表示维护范围，不表示实现已删除，也不把其中的凭据不可见模型应用到受信学校脚本。

- 当前受信源码包的授权、身份、网络、取消与 SDK 回归在 [`../scripts/`](../scripts/)。
- 共用的密钥/凭据、HTTP 传输、QuickJS host bridge 和原生页面测试仍保留在原目录；例如 `broker_credential_store_test.dart` 验证当前脚本也使用的凭据库。
- 共享 V1 输入位于 [`../../../tests/fixtures/legacy-adapters`](../../../tests/fixtures/legacy-adapters/README.md)，领域 golden 继续位于 `contract/golden/`。
- `flutter test` 自动递归发现本目录，CI 的 DEPLOY/DEV 两轮仍完整执行；没有跳过或删除旧断言。

```bash
cd client
bash tool/flutter_test.sh fvm flutter test test/legacy
bash tool/flutter_test.sh fvm flutter test test/legacy --dart-define=ELECON_TRUST_PROFILE=dev-sideload
```

外部学校 V1 夹具仍按 `adapters.pin` 获取；本地缺仓会显式跳过对应学校用例，CI 的 `ELECON_REQUIRE_ADAPTERS=1` 继续要求齐备。新源码学校包在 `school-scripts/`，不依赖外部 V1 夹具才能开发。
