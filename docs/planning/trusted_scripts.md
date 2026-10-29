# 受信学校脚本实施记录

依据：ADR-034。独立分支 feat/trusted-school-scripts，基线 a60db9f；原工作区已有登录与 bundle 修改未纳入。

- [x] 阶段 1：方向 ADR、规则覆盖与实施记录。
- [x] 阶段 2：精确域名/IP/CIDR 白名单及原生 HTTP 传输。
- [x] 阶段 3：新格式、版本/安装授权、真实凭据 API 与背景 QuickJS。
- [ ] 阶段 4：浏览器 DOM 桥接、可见操作入口与脚本安装/运行产品接线。
- [ ] 阶段 5：集成回归、文档、交叉审阅与剩余限制。

每阶段验证后 no-sign commit。不得将 AI 审阅记录为人工安全签收，不声称完成真实学校/真机验证。

阶段 2 验证：26 项网络/HTTP 测试通过（真实 loopback HTTP、DNS pinning、CIDR、跨域重定向、TLS 握手和取消）；四个相关 Dart 文件 analyze 无问题。文本响应支持 UTF-8 / 显式 Latin-1；其它编码需后续按学校样本扩展。

阶段 3 验证：20 项 manifest/凭据/真实 QuickJS 测试 + 6 项安装注册表测试通过；schema smoke（有效包与 12 项拒绝变体）、tools typecheck 通过。包括源码不在安装阶段执行、版本单调更新、持久化失败保留旧版、原始 Set-Cookie、非 UTF-8 原始字节、DOM API、取消与日志净化。新路径无需 Masker/opaque handle。
