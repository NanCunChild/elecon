# GitHub Release 验证与审批 runbook

> 本文落实 P0-13 的仓内部分，不修改 ADR、contract 或 ADR-024 trust profile。Adapter 官方签名仍严格按
> [`signing_ceremony.md`](./signing_ceremony.md) 离线执行；CI 不持有 adapter signing secret，也不出签。
> **只有 adapter 签名要求离线。** 平台签名按 workflow 正常进行：Android release 必须使用 Actions secrets
> 中的 upload keystore；macOS 在配置证书 secrets 时于 runner 上 codesign，否则产出未签名 `.app`；iOS
> 当前明确用 `--no-codesign` 产出名称带 `unsigned` 的 zip。Windows/Linux 当前没有额外代码签名步骤。

## Release chain

`.github/workflows/release.yml` 只接受已有的严格 SemVer tag（`vMAJOR.MINOR.PATCH`，可含 SemVer
prerelease/build suffix）。`scripts/release-preflight.sh` 机械检查：

1. tag 语法正确且 `refs/tags/<tag>` 已存在；
2. `workflow_dispatch` 只允许从 `refs/heads/main` 发起，event/ref 由 workflow 显式传给 preflight；
3. tag 可剥离到完整 40 位 commit SHA；
4. 该 commit 是 `origin/main` 的 ancestor；
5. 后续 reusable CI 和所有 build 均 checkout 该 SHA，而不是 tag；
6. publish 前再次解析 tag，若此前已移动则拒绝发布。

第 6 项只缩小 TOCTOU 窗口，**workflow 自身无法关闭再次检查与 GitHub Release 创建之间的 tag 移动窗口**。
剩余风险必须由仓库 required immutable tag rules 控制：禁止更新/删除 release tag，并限制 `v*` tag 创建者。

Release 的 `verification` job 调用 `.github/workflows/ci.yml` 的 `workflow_call` 入口。调用覆盖普通 CI 的
lint、workspace typecheck、server/tools smokes、external adapter validator、PII scanner、codegen diff、stdlib
diff、Flutter analyze/test/release gate、bootstrap diff 和 ledger validator。`build` 与 `publish` 都显式依赖
`verification` 和 `approval`。

build artifacts 下载完成后，`softprops/action-gh-release` 直接对既有 tag 创建/更新普通 GitHub Release、生成
release notes 并上传文件。这里没有 unsigned prerelease staging release，也没有后续替换/晋升流程。workflow
未设置 `draft` 或 `prerelease` 输入，因此 action 当前按默认值发布 non-draft、non-prerelease release；tag 中的
SemVer prerelease suffix 本身不会在本 workflow 中实现 staging/晋升。

## Repository configuration

NanCunChild 必须在 GitHub 仓库设置中创建名为 **`release`** 的 Environment，并配置 required reviewers。
仓内 `approval` job 已绑定该 Environment，但 workflow 文件无法证明或创建 reviewer 规则。Environment 未
配置保护时审批 hook 不构成人工门，因此 P0-13 checklist 必须保持未勾选。

同时保留以下外部配置：

- `main` branch protection / ruleset 必须要求 reusable CI 的全部 required checks；
- 禁止删除或更新 release tag，并限制创建 `v*` tag 的主体；
- GitHub Actions 默认 token 权限保持 read-only；仅 `publish` job 获得 `contents: write`。
- adapter signing secret、token PIN 和 PKCS#11 材料不得进入 Actions。Android/macOS 平台签名所需的
  keystore、证书与密码按 workflow 字段配置为 Actions secrets，不得与 adapter 离线密钥混用。

## Local preflight test

```bash
npm run test:release-preflight
```

测试覆盖 push/manual event-ref gate、合法 tag、非法语法、不存在 tag、非 main ancestry 和预检后 tag SHA
改变。它只创建临时本地 git 仓库，不访问远端、不签名。

## Known gap

P0-14 的 `ELECON_TRUST_PROFILE` 接线与产物级 sideload symbol/profile metadata 证明不属于本改动，未加入或
伪装成已完成。现有 release static/build gate 仍照常运行；P0-14 必须按其 landing checklist 独立实施和人工签收。
