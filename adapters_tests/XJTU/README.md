# XJTU 请求测试

- schoolId: `school-xjt`
- school: 西安交通大学
- systems: 统一认证、研究生系统、考勤、一网通办、教务通知
- status: `active`
- sensitivity: `credential-sensitive`
- inUse: 是；`dean/` recorder 和脱敏回归仍使用，其余目录作为请求结构参考

本目录整理自 `XJTUToolBox` 的西安交通大学请求路径。

各脚本只负责请求结构和响应解析，登录得到的 `requests.Session` 由调用方传入；不在夹具或脚本中保存账号、密码、cookie 或 token。

目录按服务域名划分：

- `auth/`：统一认证公开接口请求
- `gmis/`：研究生管理信息系统
- `attendance/`：本科生和研究生考勤接口
- `ywtb/`：一网通办接口
- `notice/`：教务处、研究生院和软件学院通知
- `jwapp/`：本科教务应用接口
- `dean/`：教务处挑战握手、脱敏 fixture recorder 与 ADR-009 历史证据
