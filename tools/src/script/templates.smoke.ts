/** ADR-035: execute the actual single-file templates with synthetic host APIs. */
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { packageScript } from "./package.js";

type Cookie = {
  name: string;
  value: string;
  domain?: string;
  path?: string;
  expiresDate?: number | null;
  isSecure?: boolean;
  isHttpOnly?: boolean;
  sameSite?: "Lax" | "Strict" | "None";
};
type Snapshot = { version: number; targets: Array<{ url: string; cookies: Cookie[] }> };
type CredentialOptions = { namespace?: string; type?: string; scope?: string[]; expiresAt?: number | null };
type Credential = CredentialOptions & { key: string; value: string };
type Context = {
  credentials: {
    get(key: string, options?: CredentialOptions): Promise<Credential | null>;
    set(key: string, value: string, options?: CredentialOptions): Promise<void>;
  };
  browser?: {
    open(url: string): Promise<void>;
    waitFor(selector: string, timeout: number): Promise<boolean>;
    cookies(url: string): Promise<Cookie[]>;
    setCookies(url: string, cookies: Cookie[]): Promise<void>;
    evaluate(source: unknown): Promise<unknown[]>;
  };
  fetch(url: string, init: { headers: Record<string, string> }): Promise<unknown>;
  now(): number;
  log(level: string, message: string): void;
};
type Template = {
  capabilities: { "notice.list": (context: Context) => Promise<unknown> };
  cookieHeaderForUrl?: (snapshot: Snapshot, url: string, now: number) => string;
  cookiesForRestore?: (snapshot: Snapshot, url: string, now: number) => Cookie[];
};
async function template(kind: string): Promise<Template> {
  const moduleUrl = new URL(`../../../adapters/_template/trusted/${kind}/index.js`, import.meta.url);
  const loaded = await import(moduleUrl.href);
  return (loaded.capabilities ? loaded : loaded.default) as Template;
}
const http = await template("http");
const browser = await template("browser");
const pageUrl = "https://campus.example.edu/notices";
const apiUrl = "https://campus.example.edu/api/notices";
const now = 1_800_000_000_000;
const root: Cookie = {
  name: "SID",
  value: "ROOT",
  domain: "campus.example.edu",
  path: "/",
  expiresDate: now + 60000,
  isSecure: true,
  isHttpOnly: true,
  sameSite: "Lax",
};
const page: Cookie = {
  name: "SID",
  value: "PAGE",
  domain: "campus.example.edu",
  path: "/notices",
  isSecure: true,
  isHttpOnly: true,
  sameSite: "Strict",
};
const apiCookies: Cookie[] = [
  root,
  {
    name: "SID",
    value: "API",
    domain: "campus.example.edu",
    path: "/api",
    expiresDate: now + 60000,
    isSecure: true,
    isHttpOnly: true,
    sameSite: "Strict",
  },
  {
    name: "SID",
    value: "EXACT",
    domain: ".campus.example.edu",
    path: "/api/notices",
    expiresDate: now + 60000,
    isSecure: true,
    isHttpOnly: true,
    sameSite: "None",
  },
  {
    name: "CSRF",
    value: "FORM",
    domain: "campus.example.edu",
    path: "/api/notices",
    isSecure: true,
    isHttpOnly: false,
    sameSite: "Lax",
  },
  { name: "PUBLIC", value: "VISIBLE", domain: "campus.example.edu", path: "/", isSecure: false },
  { name: "SID", value: "ADMIN", domain: "campus.example.edu", path: "/admin" },
  { name: "SID", value: "WRONG_BOUNDARY", domain: "campus.example.edu", path: "/api/no" },
  { name: "SID", value: "FOREIGN", domain: "other.example.edu", path: "/" },
  { name: "SID", value: "EXPIRED", domain: "campus.example.edu", path: "/api/notices", expiresDate: now - 1 },
  { name: "SID", value: "ANDROID_ONE" },
  { name: "SID", value: "ANDROID_TWO" },
];
const shared = new Map<string, Credential>();
const calls: string[] = [];
function credentials(scriptId: string) {
  // A script-local record with the same key must never accidentally be used.
  shared.set(`${scriptId}/browser-cookies`, { key: "browser-cookies", value: "WRONG_SCRIPT_LOCAL" });
  return {
    async get(key: string, options?: CredentialOptions) {
      assert.equal(options?.namespace, "campus.session");
      return shared.get(`${options.namespace}/${key}`) ?? null;
    },
    async set(key: string, value: string, options?: CredentialOptions) {
      assert.equal(options?.namespace, "campus.session");
      shared.set(`${options.namespace}/${key}`, { key, value, ...options });
    },
  };
}
const restored: Array<{ url: string; cookies: Cookie[] }> = [];
const selectedItems = [
  { id: "0", title: "Synthetic notice", url: `${pageUrl}/one`, source: "Campus", category: "academic" },
];
const browserContext: Context = {
  credentials: credentials("school-browser-example"),
  now: () => now,
  log: () => {},
  fetch: async () => {
    throw new Error("browser template must not make native HTTP calls");
  },
  browser: {
    async open(url) {
      assert.equal(url, pageUrl);
      calls.push("open");
    },
    async waitFor(selector, timeout) {
      assert.equal(selector, "#notice-list");
      assert.equal(timeout, 30000);
      return true;
    },
    async cookies(url) {
      calls.push(`cookies:${url}`);
      if (url === apiUrl) return apiCookies;
      assert.equal(url, pageUrl);
      return [root, page];
    },
    async setCookies(url, cookies) {
      restored.push({ url, cookies });
    },
    async evaluate(source) {
      assert.equal(typeof source, "function");
      return selectedItems;
    },
  },
};
assert.deepEqual(await browser.capabilities["notice.list"](browserContext), { items: selectedItems });
assert.deepEqual(calls, ["open", `cookies:${pageUrl}`, `cookies:${apiUrl}`]);
assert.equal(restored.length, 0);
const saved = shared.get("campus.session/browser-cookies")!;
const snapshot = JSON.parse(saved.value) as Snapshot;
assert.equal(saved.type, "cookie");
assert.deepEqual(saved.scope, [pageUrl, apiUrl]);
assert.deepEqual(snapshot.targets[0], { url: pageUrl, cookies: [root, page] });
assert.deepEqual(snapshot.targets[1], { url: apiUrl, cookies: apiCookies });
assert.equal(snapshot.targets[1]!.cookies.filter((cookie) => cookie.name === "SID").length, 9);
assert.equal(snapshot.targets[1]!.cookies[2]!.sameSite, "None");

const expected = "SID=EXACT; CSRF=FORM; SID=API; SID=ROOT; PUBLIC=VISIBLE; SID=ANDROID_ONE; SID=ANDROID_TWO";
assert.equal(http.cookieHeaderForUrl!(snapshot, apiUrl, now), expected);
const requests: string[] = [];
const httpContext: Context = {
  credentials: credentials("school-http-example"),
  now: () => now,
  log: () => {},
  async fetch(url, init) {
    assert.equal(url, apiUrl);
    assert.equal(init.headers.Cookie, expected);
    requests.push(url);
    return {
      ok: true,
      async json() {
        return { items: [{ id: 42, title: "Private notice" }] };
      },
    };
  },
};
assert.deepEqual(await http.capabilities["notice.list"](httpContext), {
  items: [{ id: "42", title: "Private notice", source: "Campus", category: "academic" }],
});
assert.deepEqual(requests, [apiUrl]);
assert.throws(
  () => http.cookieHeaderForUrl!(snapshot, "https://sub.campus.example.edu/api/notices", now),
  /cookie_snapshot_required/,
);
assert.throws(
  () => http.cookieHeaderForUrl!(snapshot, "https://campus.example.edu/admin", now),
  /cookie_snapshot_required/,
);
const httpUrl = apiUrl.replace("https:", "http:");
assert.equal(
  http.cookieHeaderForUrl!({ version: 1, targets: [{ url: httpUrl, cookies: apiCookies }] }, httpUrl, now),
  "PUBLIC=VISIBLE; SID=ANDROID_ONE; SID=ANDROID_TWO",
);

const ipUrl = "http://127.0.0.1/api/notices";
assert.equal(
  http.cookieHeaderForUrl!(
    {
      version: 1,
      targets: [
        {
          url: ipUrl,
          cookies: [
            { name: "SID", value: "PARTIAL_IP", domain: "0.0.1", path: "/" },
            { name: "SID", value: "EXACT_IP", domain: "127.0.0.1", path: "/" },
          ],
        },
      ],
    },
    ipUrl,
    now,
  ),
  "SID=EXACT_IP",
);

// Restore scoped records unchanged where known; retain unknown metadata only
// within the captured host/path and do not claim a lossless Android jar.
await browser.capabilities["notice.list"](browserContext);
assert.equal(restored.length, 2);
const apiRestore = restored.find((group) => group.url === apiUrl)!.cookies;
assert.deepEqual(
  apiRestore.find((cookie) => cookie.value === "EXACT"),
  apiCookies[2],
);
assert.equal(apiRestore.filter((cookie) => cookie.name === "SID").length, 5);
const unknown = apiRestore.filter((cookie) => cookie.value.startsWith("ANDROID"));
assert.equal(unknown.length, 2);
assert.ok(unknown.every((cookie) => cookie.domain === undefined && cookie.path === "/api/notices"));
assert.ok(
  !apiRestore.some((cookie) => ["ADMIN", "WRONG_BOUNDARY", "FOREIGN", "EXPIRED"].includes(cookie.value)),
);
assert.equal(apiRestore.find((cookie) => cookie.value === "ROOT")!.sameSite, "Lax");

// A false readiness result must not save an incomplete login or return empty
// success. Restoring existing cookies before navigation is still permitted.
let writes = 0;
let evaluations = 0;
const captureCount = calls.filter((call) => call.startsWith("cookies:")).length;
const timeoutContext: Context = {
  ...browserContext,
  credentials: {
    ...browserContext.credentials,
    async set() {
      writes++;
    },
  },
  browser: {
    ...browserContext.browser!,
    async waitFor() {
      return false;
    },
    async evaluate() {
      evaluations++;
      return [];
    },
  },
};
await assert.rejects(browser.capabilities["notice.list"](timeoutContext), /page_not_ready/);
assert.equal(writes, 0);
assert.equal(evaluations, 0);
assert.equal(calls.filter((call) => call.startsWith("cookies:")).length, captureCount);

// Both real manifests package as SDK2 without changing the container format.
for (const kind of ["http", "browser"]) {
  const directory = new URL(`../../../adapters/_template/trusted/${kind}/`, import.meta.url);
  const manifest = JSON.parse(readFileSync(new URL("manifest.json", directory), "utf8"));
  const source = readFileSync(new URL("index.js", directory), "utf8");
  assert.equal(manifest.sdkVersion, 11);
  assert.equal(manifest.version, "0.3.0");
  assert.equal(JSON.parse(packageScript(manifest, source)).format, "elecon-script/1");
}
console.log(
  "SDK11 real templates: explicit shared namespace, business-URL Cookie snapshots, path order and metadata passed",
);
