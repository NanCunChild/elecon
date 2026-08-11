# ADR-006：各校认证模式分档与对接策略

- **状态**：延后（Deferred） 本主题为调研/分类性质，非架构决策。ADR-012 的 WebView 登录方案已足够泛化，不需要 per-school-archetype 的架构级分档。
- **日期**：2026-06-14（延后声明）
- **延后理由**：各校认证模式的差异（UA 门禁 / CAS / OIDC / 微信小程序绑定）影响的是**adapter 实现策略**与**运行手册**，不是架构分层或契约设计。ADR-012 §2.2 的"核心托管 WebView 加载学校真实登录页"方案对所有认证模式通用——CAS、OIDC、JS 挑战、2FA 均由学校页面自身处理，核心只收割 session。

---

## 原定覆盖内容（留档，待条件成熟时按需展开）

1. **认证模式分类**：各校属哪一档（纯 UA 校验 / CAS SSO / OIDC 联合登录 / 微信小程序 code2session / 多因素 2FA）。
2. **各档的 adapter 对接策略**：declarative requestGraph 够不够、是否需要 imperative 多步握手、是否需要 WebView 登录配合。
3. **微信绑定天花板**：code2session 无 AppSecret 下的可解/不可解边界；依赖信息处给 API 的必要条件。
4. **逐校可行性矩阵**：已知学校的认证模式、逆向难度、维护风险评估。

---

## 建议替代形态

上述内容更适合作为 `docs/reference/school-auth-archetypes.md` 参考文档落地，而非 ADR。参考文档无需经 ADR 流程，可随新学校 adapter 的接入逐步补充。

---

## 何时重新评估

- 若发现某类认证模式**需要架构层面的支持**（如需要新增核心能力、改变 WebView 登录流程、或需要新的 manifest 字段），则应从该具体需求出发起草针对性 ADR，而非回到本"万能分类"框架。
