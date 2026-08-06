# Adapter 请求研究与夹具

这里保存学校接口的本地研究脚本、脱敏 fixture recorder 和历史诊断证据，不进入正式
adapter bundle。不得提交账号、密码、Cookie、Token 或真实学生数据（红线 #8）。

状态词表：`active` 表示仍用于回归或录制，`reference` 表示仅供实现参考，`archived`
表示只保留历史证据。敏感度描述脚本可能接触的数据，不代表仓库中保存了这些数据。

| 目录 | schoolId | 学校 / 系统 | 状态 | 敏感度 | 仍使用 |
|---|---|---|---|---|---|
| `FDU/` | `school-fudan` | 复旦大学多业务域 | reference | credential-sensitive | 是，adapter 请求结构参考 |
| `THU/` | `school-thu` | 清华大学多业务域 | reference | credential-sensitive | 是，adapter 请求结构参考 |
| `XIDIAN/` | `school-xidian` | 西安电子科技大学 IDS/E-Hall/一卡通等 | active | credential-sensitive | 是，fixture 与逆向验证 |
| `XJTU/` | `school-xjt` | 西安交通大学统一认证、教务等 | active | credential-sensitive | 是，dean recorder 与请求回归 |

目录统一使用学校规范缩写 `XJTU`；已发布 adapter 身份仍为 `school-xjt`，本次整理不改变
catalog、签名或运行时身份。
