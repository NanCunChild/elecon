# THU 请求测试

- schoolId: `school-thu`
- school: 清华大学
- systems: 统一认证、WebVPN、教务、一卡通
- status: `reference`
- sensitivity: `credential-sensitive`
- inUse: 是；用于 `school-thu` 请求结构和解析参考

本目录整理自 `/home/nancunchild/projects/thu-info-app/packages/thu-info-lib`。

脚本按业务域拆分，调用方需要传入已经准备好的 `requests.Session`。这里不实现密码登录，也不保存账号、密码、Cookie、Token 或真实学生数据；这与项目中“登录态由核心会话维护、业务模块只发请求”的边界一致。

## 字段处理约定

- WebVPN URL 保留完整编码路径，不把其中的长编码段还原或拼接成普通校内 URL。
- HTML 页面中的隐藏字段（如 `role`、`token`、`_csrf`）应先解析，再随下一次表单请求原样回传。
- 日期按源项目约定转换：课表接口使用 `YYYYMMDD`，成绩/消费页面的展示日期保持原字符串。
- 成绩页的学分、绩点和数值成绩转为 `float`；字母等级按源项目的旧 GPA 表转换。
- 响应中的姓名、邮箱、学号等字段只在内存中处理，测试夹具不得填入真实学生数据。
