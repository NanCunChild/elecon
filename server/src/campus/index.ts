/**
 * 校内授权中继（campus）—— 部署在校内堡垒机后，代取私密数据。
 *
 * 这是承重路径：经手凭证。供应链按最严标准对待（锁 lockfile、最小依赖、
 * 定期 npm audit），见 ADR-005 §3.3。凭证只存于可信核心，绝不下发给
 * adapter / UI / 公网服务端（AGENTS.md 红线 #1）。
 *
 * 尚未实现。
 */

console.log("elecon campus relay: not implemented yet");
console.log("Must be deployed inside the campus network, behind the bastion host.");
console.log("Proxies private data on behalf of authorized clients without ever");
console.log("exposing credentials to the public internet or to adapters.");
