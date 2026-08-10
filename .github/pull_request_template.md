## 做了什么
## 关联 ADR / Issue
## 红线自检（勾选）
- [ ] 未让 adapter/UI/公网触碰凭证
- [ ] 未给公网服务端加凭证存储 / 私密数据持久化
- [ ] DEPLOY 未新增未签名/devSideload 执行路径，未绕过 official 验签/身份绑定/吊销；ADR-033 §5 清单未同批落地前，未单独实现 DEPLOY 本地导入或单独删除 C3
- [ ] 改动 contract 的，已有对应 ADR 且保持向后兼容
- [ ] 新依赖已声明许可证（GPL 系已做边界隔离）
- [ ] fixtures 已脱敏，无真实学生数据
## 测试
- [ ] 客户端改动：本地或 CI 过 `client-release` / `tool/check_release_gate.sh`（release 出网与 INTERNET）
## 是否 AI 辅助生成（是→标注需重点复核的文件）
