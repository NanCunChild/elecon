# ADR-082 · 脚本创建查询表单字段

- 日期：2026-11-04
- 状态：Accepted（所有者同意控件 prefab 模式，并授权文档、工程与版本升级；实现及验证见统一计划）
- 承接：ADR-038、067、068、071、081。

## 决定

核心提供有限种通用控件，脚本创建有界数量、业务含义自由的字段实例。核心不预置所有学校的业务筛选项再让脚本启用；字段 id、标签、类型、默认值、选项及约束由同来源脚本声明。不要求学校自有字段注册核心枚举。不支持的条件不声明，disabled 用于暂不可用的交互状态，并提供原因。标准业务含义不从字段名/标签猜测；可选标准语义绑定留待有具体跨学校消费者时另行冻结，不阻塞学校自有字段。

原生页面拥有布局、可访问性、草稿和显式提交；脚本解释业务组合、获取动态选项、构造学校请求、分页并归一标准结果。输入表单自由不改变输出领域含义，不下发 Widget tree、HTML 或代码。筛选读取和查询都沿已有同包、批准 digest、Profile、取消和网络边界；不提供命令绑定。

## query.controls 2.0

首片目标仍为 `grades.list`、`classroom.available`，保留 1.0 原语义及精确 schema 快照。

输入为 `{target, current?, changed?}`：current 是当前草稿的字段值对象；changed 是本次改变的字段 id。没有 current 时读取初始表单；元数据读取是无交互只读请求，不能代替提交或自动触发控制。

输出为 `{target,title,submitLabel,controls}`，controls 允许 0–32 个实例。每项必填 `id/kind/label`，可选 `description/required/disabled/disabledReason/initialValue/options/minimum/maximum/integer/maxLength/dependsOn/timeZone`：

- `kind` 为 text、number、boolean、select、multiSelect、date、timeRange。同一类型可以出现任意多个实例，受总量上限约束。
- id 为 `^[a-z][a-zA-Z0-9._-]{0,63}$`，不得为 prototype/constructor/__proto__；同组唯一。值只通过独立 `filters` 对象传给查询，不提升为身份、来源、configure 或其他宿主参数。
- text/date/select 为字符串；number 为有限数字，integer=true 时须整数；boolean 为布尔值；multiSelect 为不重复的字符串数组；timeRange 为 `{start,end}`，HH:mm，同日起点早于终点。日期为真实 YYYY-MM-DD。时间条件须有 timeZone 描述学校时间含义，不从设备地区猜学校时区。
- 每个选择字段最多 200 个唯一选项，选项 `{value,label}`；多选最多 32 项，字符串值最多 512 字符。表单元数据与 filters/current 分别限制为 128 KiB/32 KiB UTF-8。数字上下限、文本长度、默认值类型和选项一致性、纯文本标签均校验。
- dependsOn 为同组存在的不同字段 id，不得成环。改变上级条件清除递归下级值，再将草稿发送同来源脚本，重建其返回的表单；不静默替换用户已有有效选择。失效选项清除。按草稿修订丢弃迟到响应，读取失败保留草稿、显示重试并阻止以失效元数据提交。
- 可选空值省略，false 和 0 是有效值。禁用字段不提交；未声明字段不透传。必填/格式错误在表单中指出；学校仍须在最终查询重验所有值及业务组合。后台调用不通过表单也不能绕过学校校验。

条件仅在用户提交时原子应用；取消保持原查询。来源、批准代际、数据身份、语言变化使草稿和迟到结果失效。缓存按完整规范化 filters 隔离，表单元数据不写业务缓存。

## 学校参数与标准输出

`params.grades.list` 升 1.1、`params.classroom.available` 升 1.2，加入有界 filters；旧标准参数含义保持。支持新表单的脚本可以把查询范围完全放在 filters 内，核心不再强加楼栋、日期、学期控件。旧包继续使用既有原生/1.0控件。输入支持通过同包 query.controls 2.0 声明协商，不假定所有旧包接受 filters；已有 SDK17 运行端口足够，无新的运行权限或 SDK 全局接口。

西电首片覆盖学期与空教室日期、校区/楼栋、房间、学校时段、教室类型和教学/考试座位数。学校实际无数据的条件不伪造；源站不支持过滤但响应有数据时，可在脚本完成分页后过滤。无容量不当作0，也不当作满足阈值。实际过滤条件及覆盖范围随结果说明，当前结果内筛选不能声称查询全校。

`classroom.available` 升 1.3，新增可选 `items[].roomType`（label 必填、code 可选）、`teachingCapacity/examCapacity`（非负整数，单位人），旧 capacity 含义不变；新增可选顶层 appliedFilters（实际采用的字段值对象）、coverage（complete 必填布尔、description 可选纯文本，完整性针对实际条件）。保留 1.1/1.2 验证器。时间轴与旧布局都显示可用的教室属性。

西电从学校列表保留座位数、教室类型与节次占用类型，原因沿已有 intervals.reason 返回。样本里为空的明细时间不构成更精确时间证据；课间未知仍保持未知。独立按需借用详情、跨午夜查询及其他领域目标不由本次表单实现自动宣称完成。

## 迁移与验证

包声明新 query.controls/classroom schema 后重新批准 digest，旧宿主拒绝未知版本；未升级包保持 1.0 表单和旧标准参数。同步 registry、schema 快照、生成器/生成物、SDK 类型、学校包与文档。App 本地版本升级为 0.8.0+11，默认与 Apple manifest 同步，无发布/tag/部署。

验证包含多实例与学校差异、数字/布尔/多选/日期/时段、约束/未知键/依赖环、元数据失败与重试、来源和身份变化、迟到响应、取消无查询、参数缓存隔离；学校用合成 HAR 结构验证过滤与未知容量、类型、多占用原因、分页完整性；保留旧包回归和真实 QuickJS。原始 HAR 不入库，自动测试不替代真实学校、真机或人工核心审阅。
