# 西电教师查询：公开接口观察

观察时间：2026-11-01。实施决策见 [ADR-050](../adr/adr_050_faculty_search.md)。本记录仅确认小预算公开查询的当时行为，不代表持续可用性、人工安全签收或全站数据完整性。

## 证据与范围

读取了[教师主页官网](https://faculty.xidian.edu.cn/)及官网加载的 [advancesearch.js](https://faculty.xidian.edu.cn/system/resource/tsites/advancesearch.js)，再发出三次小页公开查询（同一姓名的第 1/2 页、一个合成不存在的关键词）。没有登录、没有抓取全站、没有把真实教师页面或联系方式保存为仓库夹具。

首页 `tsites_load_data_options` 公开提供 `viewid=125262`、`viewUniqueId=125262`、`siteOwner=2124906779`。页面脚本以 GET 请求 `/system/resource/tsites/advancesearch.jsp`，参数包括 `teacherName`、`searchDirection`、`pageindex`、`pagesize`、学院/学科等筛选值。实现只使用姓名/关键词和研究方向筛选；固定组件参数由可更新学校脚本维护，不下载或执行官网 JavaScript。

响应根含 `totalnum`、`totalpage`、`pageindex`、`teacherData`。请求页码从 1 开始，第 1/2 页分别返回 `pageindex=0/1`。实现要求响应 `pageindex=请求页码-1`，避免源站忽略分页时把第一页错标成后续页；归一输出使用请求页码。零匹配响应为 `totalnum=0`、`totalpage=1`、空 `teacherData`。姓名查询由来源决定匹配语义，不能假定精确匹配。同名教师可有不同 `teacherId`。

每条数据可含 `teacherId`、`teacherName/showName`、`collegeName/unit`、`prorank`、`discipline`、`profileSummary/profile`、`researchDirectionList`、`url`，以及其他字段。实现仅输出标准契约需要的公开学术信息与同源 HTTPS 主页，忽略手机号、地址、性别等字段；HTML 归一为纯文本，空字段省略。请求不使用认证 cookie jar 或凭据，且拒绝重定向。

## 维护与验收

查询按用户提交/翻页一次一页，默认 10 条、最大 20 条；不自动补页和预加载，不存持久缓存。接口布局变化、缺失分页信息或损坏条目保持失败，不能伪装成无结果。CI 仅使用合成 fixture。真机原生查询、弱网和官网改版仍需后续人工验收。
