# Hermes 上游对齐（2026-11-04）

依据用户要求审计本地 `~/projects/Hermes-Atrust`。其已提交 HEAD 为 `061de04a699902196475227aece37923e08d646e`；未提交的桌面/CLI 工作不属于 elecon 所用八个 crate，未复制。此记录覆盖 ADR-062/064/066/075 既定的应用内 TCP 桥，不增加系统 VPN、TUN、公共代理或脚本原生接口。

## 同步范围

由旧固定提交 `271a547d73c3839365a1995d1a6d72ed915e1458` 更新八个 crate 的已提交源码：资源区间/域名索引与传输策略、网关失效后禁止新操作、原子会话替换及旧连接取消、节点健康与重连退避、L3 阻塞写取消、实际发送后的心跳计数、分片拒绝、资源身份变化失效及有界流接收。L3 代码仍是上游依赖内部实现，不向脚本开放。

保留 elecon 本地保护：严格证书 pin 与真实 TLS 签名校验、按域名授权后使用已核准数字目标、从最新 Cookie jar 读取 SID 且删除后不回落旧值、秘密标识清零、移除明文 session store。短调用桥关闭额外的自动 TLS 节点探测批次；已有逐候选建链保留。桥的 status、缓存 DNS 和 dial 现在都检查明确的会话失效状态，避免旧资源表导致假 ready。要求 L3 的资源明确失败，不改为直连。

上游新增的系统 TUN、代理入口、桌面客户端、明文文件持久化均未纳入。既有 TCP 隧道 DNS 保留；`atrust-net` 的 UDP、TTL DNS 与 TCP fallback 是另一传输栈，未冒称已接入。控制面 antiMITM 与 TCP 版本协商仍以既有研究记录为准。

## 依赖与验证

MIT 来源与许可证不变。Cargo.lock 只为 atrust-client 增加已锁定的 futures-util（生产）和 url（测试）引用；无第三方包或版本新增，THIRD_PARTY 与 Flutter 许可证副本不需重生成。

`cargo test --locked --workspace` 共 298 项通过；桥的 16 项再次通过，包含真实合成本机 TLS/指定目标/SID轮换/删除/一次性UDS及新增的明确失效阻断断言。`cargo clippy --locked --workspace --all-targets -- -D warnings` 通过，Linux动态库构建通过。Android ARM64 使用 Flutter 选定的 NDK 28.2.13676358 构建通过。

没有请求真实学校网关、没有复制上游真实验证资料或使用真实学生数据。自动回归与编译不替代真实网关、设备和核心网络人工审阅。回滚可恢复旧固定源码与锁文件，C ABI 仍为版本1。
