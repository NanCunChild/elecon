# ADR-088：书目检索

状态：Accepted（2026-11-04，按用户授权实施）。

library.search/1.0 是只读书目检索，与个人 library.loans 独立。输入 query 为非空关键词、page 从1开始、size 1至50；输出 query/page/size/hasNext/items，total 可缺失。每个书目 bookId 是源站书目记录ID而非借阅条码，title 必需；author/isbn/publisher/callNumber 按来源提供，缺失不补造。分页查询绑定来源和参数并可在受保护缓存恢复。

借阅二级页上方为书目查询，下方为当前借阅；首页只显示借阅摘要。西电适配依据本地 traintime_pda 的 OPAC /find/unify/search 协议重新实现，合成夹具验证，不复制第三方实现或声称学校实测。失败和未知响应不能变成空结果，不扇出封面请求。

新增schema、registry、SDK生成物与打包消费者同步；不改变旧loans语义。回滚隐藏search声明并恢复旧包，旧宿主拒绝未知能力。真实源站分页字段与人工核心审阅另行验收。
