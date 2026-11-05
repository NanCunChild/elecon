# ADR-096 · 系统教室查询的明确楼栋与学校时区

- 日期：2026-11-05
- 状态：Accepted（按所有者接续落地授权实施；平台与真实学校验收独立记录）。
- 承接：ADR-074、082、083、085；只调整系统工具的有界查询范围，不修改脚本领域契约。

## 问题与决定

`findAvailableClassrooms` 接受空楼栋，但学校可能要求楼栋；现有错误被归成无提示的 `queryFailed`。任意 query.controls 2.1 字段 ID/标签不具备标准业务语义，不能据名称猜出楼栋或把字段默认值当作用户选择。

系统工具首片收窄为用户明确指定一个标准 `buildingId` 的查询。保留可空的原生函数签名以提供条件提示；空值不调用 `classroom.available`，返回 `configurationRequired/buildingRequired`、`missingParameters: [buildingId]` 和固定的 `elecon://feature/classroom` 页面入口。已有 App 内学校表单仍支持各校的查询范围，不能由此强制其只能单栋。`describeAvailableServices` 与原生函数说明同步报告此条件。

为让调用者取得可用标识，在当前教室共享已获授权且同一批准包声明 `classroom.buildings@1.0` 时，可作一次非交互、有界目录读取，返回标准 `buildingId/building/campus` 投影。绝不跨包拼接目录、不自动选择首项、不运行 `classroom.available`、不登录或加载任意表单。无标准 ID、能力缺失、目录失败或部分结果时仍提供固定原生入口及明确的目录状态，不凭空生成标识或宣称完整目录。选项限 200 条且整份响应仍限 128 KiB；来源、取消、身份及授权检查与实际查询相同。固定页面入口只导航正常恢复后的当前身份，需重新选择条件，不承诺恢复原系统请求或继续执行。

学校时区使用该次 `classroom.available@1.2/1.3` 的标准顶层 `timeZone`，不读取首条占用记录、设备时区或开放扩展字段来猜测。Android 使用平台 IANA 规则检查输入两端的学校墙钟日期、时间和显式 UTC offset 是否有效，包含夏令时缺口与重叠。缺失或非法时区返回 `unavailable/schoolTimeZoneUnknown`；有效时区与输入冲突返回 `configurationRequired/schoolTimeZoneMismatch`，附学校时区与固定入口，不发布可能误解的可用教室列表。当前只能在只读查询返回后核验；出网前的动态时区发现需后续显式标准元数据，不能声称本片已经完成。

课表工具仅在声明 `schedule.week@1.3` 时投影标准 `timeZone`；旧版开放 schema 的同名扩展不被提升成标准字段。仍只提供原四个具名只读函数，不增加任意字段、脚本、身份或 URL 输入。

## 兼容与验证

不分配新 SDK 或业务 schema 版本，不修改 query.controls；这是现有试验性系统工具的明确范围调整，Android 生成说明随应用构建更新。旧调用省略楼栋会得到可操作的配置状态，已有带楼栋调用继续按来源与身份执行。更新应用不替代当前进程内的逐项共享授权；回滚应用恢复旧工具行为，不迁移学校数据。

合成测试覆盖缺楼栋只取同来源目录、无授权零执行、无 ID/超限/恶意扩展的有界投影、目录中的来源切换/撤销、时区未知/无效/offset 冲突/夏令时，以及旧课表扩展不外泄。原生构建核对函数说明及 IANA 校验；平台注册、系统助手可调用和真实学校可用性分别验收。
