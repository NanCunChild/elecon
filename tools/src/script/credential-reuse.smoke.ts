/** SDK15 synthetic package admission; does not contact any gateway. */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { packageScript } from "./package.js";

const base = JSON.parse(
  readFileSync(
    new URL("../../../adapters/_template/trusted/credential-reuse/manifest.json", import.meta.url),
    "utf8",
  ),
);
const source = readFileSync(
  new URL("../../../adapters/_template/trusted/credential-reuse/main.js", import.meta.url),
  "utf8",
);
assert.doesNotThrow(() => packageScript(base, source));
assert.doesNotThrow(() =>
  packageScript(
    {
      ...base,
      homeTitle: "Synthetic home",
      capabilities: [
        ...base.capabilities,
        { id: "notice.list", schema: "elecon.notice.list", schemaVersion: "1.1" },
      ],
      home: [{ capability: "notice.list", params: {}, ttlSeconds: 300 }],
      cards: [{ type: "notice", defaultVariant: "regular" }],
    },
    source,
  ),
);
for (const change of [
  (m: typeof base) => {
    m.sdkVersion = 14;
  },
  (m: typeof base) => {
    m.accounts[1].credentialReuse.sourceAccountId = "missing";
  },
  (m: typeof base) => {
    m.accounts[1].credentialReuse.sourceAccountId = "vpn";
  },
  (m: typeof base) => {
    m.accounts[1].credentialReuse.gatewayUrl = "https://other.example.invalid";
  },
  (m: typeof base) => {
    m.accounts[1].credentialReuse.gatewayUrl = "https://vpn.example.invalid/";
  },
  (m: typeof base) => {
    delete m.accounts[1].status;
  },
  (m: typeof base) => {
    m.accounts[1].credentialReuse.extra = true;
  },
  (m: typeof base) => {
    m.network.ipAllow = [];
  },
]) {
  const manifest = structuredClone(base);
  change(manifest);
  assert.throws(() => packageScript(manifest, source));
}
console.log(
  "SDK15 credential reuse: valid template, inherited home declarations and 8 invalid declarations passed",
);
