# ADR-035：脚本凭据描述符与 SDK 2

- **Decision**：Accepted（2026-10-29；依据所有者对多凭据、冲突、唯一描述符和版本规范的检查与修复授权；不代表人工安全签收）
- **Landing**：见 [受信脚本实施记录](../planning/trusted_scripts.md)。
- **覆盖**：细化 ADR-034 §2/§3；保留其同校凭据访问权限与 V1 official 兼容边界。

## 1. 问题

SDK 1 默认把同校脚本的同名键合并，并隐式查找旧登录 ref；两个独立脚本使用 `session` 可能覆盖，刷新还可能重置旧条目的 type/scope。仅返回 key 不能区分同名凭据的来源。浏览器还存在同名 Cookie 的 domain/path 区别，不能把 Cookie 名直接视为凭据唯一键。

## 2. 描述符与访问

SDK 2 的地址是 `(schoolId, namespace, key)`。schoolId 由宿主绑定当前学校；namespace 默认稳定脚本 id，与脚本版本无关。get/set/delete 接受可选 `{namespace}`，显式共享同一 namespace 即可跨脚本复用；namespace 是寻址方式，不是授权边界。同校受信脚本仍能通过 list 发现并读取该校全部可用凭据，不增加权限语言。

记录返回稳定 id、namespace、key 以及原有 value/type/scope/expiresAt/expired。SDK 2 list 不折叠不同 namespace 下的同名键；`get(record.key, {namespace: record.namespace})` 可往返。新物理 ref 使用有版本前缀的无歧义组合编码；组件校验禁止分隔符。主密钥与其他学校仍不可访问。

`@legacy` 显式寻址当前学校的旧登录 ref；`@preview1` 显式寻址 SDK 1 创建的学校共享键。默认 SDK 2 不隐式覆盖这两类记录。SDK 1 包继续保持原查找语义，仅供预览兼容；其语义不因宿主升级静默改变。旧数据不猜测脚本归属，不自动复制。脚本作者可通过 list 挑选旧记录、读取后写入新 namespace，再按需显式删除旧记录。卸载仍保留凭据，登出删除当前学校全部 namespace。

写入已有记录时，省略的 type/scope/expiresAt 保持原值；显式 expiresAt:null 清除期限，scope:[] 清除范围。相同完整地址的 set 是有意更新；不同地址独立保存。若物理槽位已属于其他学校或含不一致描述符，报告冲突，不覆盖。需要一起轮换的 access/refresh token 可存成一个 JSON 记录；不为此引入跨记录事务 DSL。

## 3. 保存与失败

set/delete resolve 表示宿主已接受本地修改；持久化档位不变。一次脚本结束，无论业务成功、输出校验失败或认证后的业务异常，宿主都等待本次存储后端的耐久屏障；写失败返回稳定错误，不报告成功。取消后不接受晚到写入，已完成的写入仍保存，不回滚已轮换的远端凭据。内存档不承诺跨进程保存。

## 4. 版本与 Cookie

包格式继续 `elecon-script/1`（JSON 容器不变）；SDK 2 表示凭据寻址与元数据更新语义，宿主明确识别 1/2，未知 SDK 拒绝。脚本 version 仍为三段数值版本，SDK/源码/权限变化均须提升脚本版本并重新确认；SDK 版本不替代脚本版本，也不与旧 `elecon-bundle/3` 比较。SDK 1 的相同内容重导入保留原语义，不能自动转换为 SDK 2。

新模板使用 SDK 2；有意共享的凭据显式使用同一 namespace。Cookie 集合保留 name/domain/path、有效期、Secure/HttpOnly/SameSite；采集和构造请求头以实际业务 URL 为依据。多个系统、不同路径或不同名字的 Cookie 不因只取 name 被合并。浏览器平台能见度与原生实测限制仍按 ADR-034 §5。

## 5. 验证

覆盖不同脚本/学校同名键、显式共享、描述符往返、SDK 1/旧数据访问、元数据保留、失败保存、重启、多 Cookie path/domain/SameSite、SDK/版本拒绝与模板兼容。新增行为的实现和自动回归不能替代人工审阅。
