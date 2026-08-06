# FDU 请求测试

- schoolId: `school-fudan`
- school: 复旦大学
- systems: 统一认证、教务、一卡通、生活服务、通知
- status: `reference`
- sensitivity: `credential-sensitive`
- inUse: 是；用于 `school-fudan` 请求结构和解析参考

本目录整理自 `/home/nancunchild/projects/DanXi/lib/repository/fdu`，按服务域名保存复旦大学请求结构。

脚本只负责请求与脱敏后的基础解析，登录产生的 `requests.Session` 由调用方传入；目录中不保存账号、密码、Cookie、Token 或真实学生数据。

- `edu/`：教务课表、考试、成绩和 GPA
- `auth/`：统一认证请求结构
- `data/`：数据中心、消费和电费历史
- `ecard/`：一卡通页面和消费记录
- `life/`：宿舍电费、校车、图书馆
- `notice/`：本科生院和研究生院通知
- `graduate/`：研究生课表与成绩
- `local/`：校内局域网空教室
