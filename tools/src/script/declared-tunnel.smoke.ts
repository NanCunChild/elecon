/** Synthetic SDK16 admission; no gateway traffic. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { packageScript } from "./package.js";

const base = JSON.parse(
  readFileSync(
    new URL("../../../adapters/_template/trusted/tunnel-account/manifest.json", import.meta.url),
    "utf8",
  ),
);
const source = readFileSync(
  new URL("../../../adapters/_template/trusted/tunnel-account/main.js", import.meta.url),
  "utf8",
);
assert.doesNotThrow(() => packageScript(base, source));
for (const change of [
  (m: typeof base) => {
    m.sdkVersion = 15;
  },
  (m: typeof base) => {
    m.accounts[0].appTunnel.gatewayUrl = "http://vpn.example.invalid";
  },
  (m: typeof base) => {
    m.accounts[0].appTunnel.nodeCertificateSha256 = "invalid";
  },
  (m: typeof base) => {
    m.accounts[0].appTunnel.loginMode = "web";
    m.accounts[0].appTunnel.loginDomain = "unverified";
  },
  (m: typeof base) => {
    m.capabilities[1].appTunnelAccountId = "missing";
  },
  (m: typeof base) => {
    m.accounts[0].appTunnelAccountId = "vpn";
  },
  (m: typeof base) => {
    m.school.type.name = "\u202einvalid";
  },
  (m: typeof base) => {
    m.school.name = " ";
  },
  (m: typeof base) => {
    m.network.ipAllow = [];
  },
]) {
  const m = structuredClone(base);
  change(m);
  assert.throws(() => packageScript(m, source));
}
const web = structuredClone(base);
web.accounts[0].appTunnel.loginMode = "web";
assert.doesNotThrow(() => packageScript(web, source));
console.log("SDK16 declared tunnel: password/web templates and 9 invalid declarations passed");
