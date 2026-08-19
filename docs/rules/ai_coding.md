# 规则 · AI 编程纪律

配合 [`AGENTS.md`](../../AGENTS.md) 阅读。立场：**AI 提议，人负责。** AI 可以承担大量编码，但合并的责任、安全敏感路径的判断，始终在人。

---

## 1. 产出前自检清单（AI 每次改动前逐条过）

- [ ] 已读 ADR-000 与本次改动相关的 `docs/rules/` 细则。
- [ ] adapter bundle 只有在 official 门或用户 digest trust 通过后才执行；iOS runtime 仍为 official-only。
- [ ] **未**给公网哑服务（`server/src/public`）增加凭证存储或私密数据持久化。
- [ ] 私密数据只在用户设备侧经 direct、系统 VPN 或 official transport/app-tunnel 访问学校；未新增项目中继或公网私密路径。
- [ ] adapter 所有网络仍经过宿主出口，未新增 raw socket、Node 网络模块、WebView、原生 FFI 或其他旁路。
- [ ] `.eleb` 只有 official、已确认 local signer 或迁移期已确认 unsigned 才执行；无效签名不得降级 unsigned，unsigned 退役门未被绕过。
- [ ] Credential Store 的 profile 由宿主绑定且 adapter 永不跨 profile；同 profile 以 `adapterId` namespace 隔离，跨 adapter 访问只允许 manifest 对 exact target 声明的 `read`、`write`、`delete`，未暴露全局裸 ref 或 wildcard namespace。
- [ ] 若动了 `contract/`：已有对应 ADR，且保持向后兼容。
- [ ] adapter 仍在背景 isolate 执行，未引入 UI 线程同步阻塞。
- [ ] 新增/修改的夹具已脱敏，无真实学生数据。
- [ ] 新依赖已声明许可证；GPL 系已确认边界隔离。

**任一项无法打勾 → 不要提交该改动，改为提出问题或开 ADR。**

---

## 2. 行为约束

- **范围不蔓延**：只做被要求的事。若实现过程中发现需要改核心/契约，**停下来报告并建议开 ADR**，不要静默重构（红线 #10）。
- **依赖要透明**：不顺手 `npm i` / `go get`。新依赖单列、说明用途与许可证。
- **不自证正确**：安全敏感路径（核心/凭证/传输/签名）的实现与测试不得由 AI 独自闭环；AI 不得通过放宽断言/删用例让 CI 变绿。
- **隐私优先**：处理或生成测试数据时，绝不写入真实学生信息；遇到疑似真实抓包，提示先脱敏。
- **可追溯**：AI 辅助的 commit 加 `Assisted-by:` 行，PR 标注需重点复核的文件。
- **注释引用出处**：涉及安全、信任、契约或架构决策的文档注释，须标注决策来源
  （ADR 编号 + 小节，如 `ADR-009 §2.4`；红线用 `红线 #n`；评审结论用 PR 号）。
  安全敏感文件（凭证/broker/签名/传输路径）文件头加 `🔒` 标记与适用红线。
  没有出处的"看起来合理"的安全注释视为漂移信号——审阅时应要求补出处或删除。
  本条把仓库既有惯例固化为规则，人与 AI 一体适用。

---

## 3. 升级信号（出现即停手，交回人工 / 开 ADR）

- 需要改 `contract/`（schema 或 manifest 规范）。
- 需要改变 official、local digest trust、iOS official-only 或未来签名者信任的执行准入语义。
- 需要触碰凭证保管、broker 注入逻辑、签名或吊销。
- 需要给公网服务端加状态/持久化。
- 需要引入 GPL 系或来源/许可证不明的依赖。

这些都属于"承重墙级"决策——它们的对错由人和 ADR 定，不由一次实现顺手定。
