/* 🔒 ELeB tools boundary, ADR-005 §§2.1-2.2 and 7. */
import { createHash, createPublicKey, verify as edVerify, type KeyObject } from "node:crypto";
import { deflateRawSync, inflateRawSync } from "node:zlib";

const PACKED = 64 * 1024 * 1024,
  UNPACKED = 256 * 1024 * 1024,
  SINGLE = 128 * 1024 * 1024;
const decoder = new TextDecoder("utf-8", { fatal: true });
const r16 = (b: Buffer, n: number) => b.readUInt16LE(n),
  r32 = (b: Buffer, n: number) => b.readUInt32LE(n);
const w16 = (b: Buffer, n: number, v: number) => b.writeUInt16LE(v, n),
  w32 = (b: Buffer, n: number, v: number) => b.writeUInt32LE(v >>> 0, n);
function crc32(data: Uint8Array) {
  let c = 0xffffffff;
  for (const x of data) {
    c ^= x;
    for (let i = 0; i < 8; i++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) >>> 0;
}
function pathBytes(path: string) {
  const b = Buffer.from(path);
  if (
    b.length > 256 ||
    !path ||
    path.includes("\\") ||
    path.includes("\0") ||
    path.startsWith("/") ||
    path.split("/").some((x) => x === ".." || x === "." || x === "")
  )
    throw new Error("invalid ELeB path");
  if (decoder.decode(b) !== path) throw new Error("invalid UTF-8 path");
  return b;
}

export interface ZipEntry {
  path: string;
  data: Buffer;
  method?: 0 | 8;
}
export interface ParsedZipEntry {
  path: string;
  data: Buffer;
  method: 0 | 8;
  packedSize: number;
}
export function writeDeterministicZip(entries: readonly ZipEntry[]) {
  if (entries.length > 256) throw new Error("too many entries");
  const sorted = [...entries].sort((a, b) => Buffer.compare(pathBytes(a.path), pathBytes(b.path)));
  const seen = new Set<string>();
  const locals: Buffer[] = [],
    centrals: Buffer[] = [];
  let offset = 0;
  for (const e of sorted) {
    const name = pathBytes(e.path);
    if (seen.has(e.path)) throw new Error("duplicate path");
    seen.add(e.path);
    const method = e.method ?? 0;
    const packed = method === 8 ? deflateRawSync(e.data, { level: 9 }) : e.data;
    if (method !== 0 && method !== 8) throw new Error("unsupported method");
    const l = Buffer.alloc(30 + name.length + packed.length);
    w32(l, 0, 0x04034b50);
    w16(l, 4, 20);
    w16(l, 6, 0x800);
    w16(l, 8, method);
    w32(l, 14, crc32(e.data));
    w32(l, 18, packed.length);
    w32(l, 22, e.data.length);
    w16(l, 26, name.length);
    name.copy(l, 30);
    packed.copy(l, 30 + name.length);
    locals.push(l);
    const c = Buffer.alloc(46 + name.length);
    w32(c, 0, 0x02014b50);
    w16(c, 4, 20);
    w16(c, 6, 20);
    w16(c, 8, 0x800);
    w16(c, 10, method);
    w32(c, 16, crc32(e.data));
    w32(c, 20, packed.length);
    w32(c, 24, e.data.length);
    w16(c, 28, name.length);
    w32(c, 38, 0x81a40000);
    w32(c, 42, offset);
    name.copy(c, 46);
    centrals.push(c);
    offset += l.length;
  }
  const body = Buffer.concat(locals),
    cd = Buffer.concat(centrals),
    end = Buffer.alloc(22);
  w32(end, 0, 0x06054b50);
  w16(end, 8, entries.length);
  w16(end, 10, entries.length);
  w32(end, 12, cd.length);
  w32(end, 16, body.length);
  return Buffer.concat([body, cd, end]);
}
export function parseBoundedZip(zip: Buffer): ParsedZipEntry[] {
  if (zip.length > PACKED) throw new Error("packed ZIP exceeds limit");
  const e = zip.lastIndexOf(Buffer.from([80, 75, 5, 6]));
  if (e < 0 || e + 22 !== zip.length) throw new Error("missing or non-canonical EOCD");
  if (zip.includes(Buffer.from([80, 75, 6, 6])) || zip.includes(Buffer.from([80, 75, 6, 7])))
    throw new Error("Zip64 forbidden");
  const count = r16(zip, e + 10),
    cdSize = r32(zip, e + 12),
    cd = r32(zip, e + 16);
  if (
    count > 256 ||
    r16(zip, e + 4) !== 0 ||
    r16(zip, e + 6) !== 0 ||
    r16(zip, e + 8) !== count ||
    cd + cdSize !== e
  )
    throw new Error("invalid central directory");
  let p = cd,
    total = 0,
    packedTotal = 0;
  const names = new Set<string>(),
    out: ParsedZipEntry[] = [];
  for (let i = 0; i < count; i++) {
    if (p + 46 > e || r32(zip, p) !== 0x02014b50) throw new Error("invalid central entry");
    const flags = r16(zip, p + 8),
      method = r16(zip, p + 10),
      crc = r32(zip, p + 16),
      ps = r32(zip, p + 20),
      us = r32(zip, p + 24),
      nl = r16(zip, p + 28),
      el = r16(zip, p + 30),
      cl = r16(zip, p + 32),
      lo = r32(zip, p + 42);
    const madeBy = r16(zip, p + 4),
      attrs = r32(zip, p + 38);
    if (
      flags & 9 ||
      !(flags & 0x800) ||
      (method !== 0 && method !== 8) ||
      el !== 0 ||
      cl !== 0 ||
      us > SINGLE ||
      (madeBy >> 8 === 3 && ((attrs >>> 16) & 0xf000) !== 0x8000)
    )
      throw new Error("forbidden ZIP fields");
    const name = decoder.decode(zip.subarray(p + 46, p + 46 + nl));
    if (names.has(name)) throw new Error("duplicate path");
    names.add(name);
    pathBytes(name);
    if (
      lo + 30 + nl + ps > cd ||
      r32(zip, lo) !== 0x04034b50 ||
      r16(zip, lo + 6) !== flags ||
      r16(zip, lo + 8) !== method ||
      r16(zip, lo + 26) !== nl ||
      r16(zip, lo + 28) !== 0 ||
      decoder.decode(zip.subarray(lo + 30, lo + 30 + nl)) !== name
    )
      throw new Error("local-central mismatch or overlap");
    const raw = zip.subarray(lo + 30 + nl, lo + 30 + nl + ps);
    let data: Buffer;
    try {
      data = method === 0 ? Buffer.from(raw) : inflateRawSync(raw, { maxOutputLength: SINGLE });
    } catch {
      throw new Error("invalid compressed data");
    }
    if (data.length !== us || crc32(data) !== crc) throw new Error("CRC mismatch");
    total += us;
    packedTotal += ps;
    if (total > UNPACKED || total > 20 * Math.max(1, packedTotal))
      throw new Error("ZIP unpacked/ratio limit");
    out.push({ path: name, data, method: method as 0 | 8, packedSize: ps });
    p += 46 + nl + el + cl;
  }
  if (p !== e) throw new Error("central directory size mismatch");
  return out;
}
export function looksLikeEleb(bytes: Buffer) {
  return (
    bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04])) ||
    bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x05, 0x06]))
  );
}

type JsonValue = null | boolean | string | number | JsonValue[] | { [key: string]: JsonValue };
class Reader {
  constructor(
    private s: string,
    private i = 0,
    private manifest = false,
  ) {}
  parse() {
    const v = this.value();
    this.ws();
    if (this.i !== this.s.length) throw new Error("trailing JSON");
    return v;
  }
  private ws() {
    while (/\s/.test(this.s[this.i] ?? "")) this.i++;
  }
  private value(): JsonValue {
    this.ws();
    const c = this.s[this.i];
    if (c === "{") return this.obj();
    if (c === "[") return this.arr();
    if (c === '"') return this.str();
    for (const [x, v] of [
      ["true", true],
      ["false", false],
      ["null", null],
    ] as const)
      if (this.s.startsWith(x, this.i)) {
        this.i += x.length;
        return v;
      }
    const m = this.s.slice(this.i).match(/^-?(?:0|[1-9]\d*)(?:\.\d+|[eE][+-]?\d+)?/);
    if (!m) throw new Error("invalid JSON");
    this.i += m[0].length;
    if (this.manifest && /[.eE]/.test(m[0])) throw new Error("manifest floating point forbidden");
    const n = Number(m[0]);
    if (!Number.isSafeInteger(n)) throw new Error("unsafe JSON number");
    return n;
  }
  private str() {
    const start = this.i++;
    while (this.i < this.s.length) {
      const c = this.s[this.i++];
      if (c === "\\") {
        this.i++;
        continue;
      }
      if (c === '"') {
        const v = JSON.parse(this.s.slice(start, this.i)) as string;
        for (let j = 0; j < v.length; j++)
          if (
            v.charCodeAt(j) >= 0xd800 &&
            v.charCodeAt(j) <= 0xdfff &&
            !(
              v.charCodeAt(j) >= 0xd800 &&
              v.charCodeAt(j) <= 0xdbff &&
              v.charCodeAt(j + 1) >= 0xdc00 &&
              v.charCodeAt(j + 1) <= 0xdfff
            )
          )
            throw new Error("lone surrogate");
        return v;
      }
      if (c !== undefined && c < " ") throw new Error("invalid JSON string");
    }
    throw new Error("unterminated string");
  }
  private arr(): JsonValue[] {
    this.i++;
    const a: JsonValue[] = [];
    this.ws();
    if (this.s[this.i] === "]") {
      this.i++;
      return a;
    }
    while (true) {
      a.push(this.value());
      this.ws();
      if (this.s[this.i] === "]") {
        this.i++;
        return a;
      }
      if (this.s[this.i++] !== ",") throw new Error("invalid array");
    }
  }
  private obj() {
    this.i++;
    const o: { [key: string]: JsonValue } = {},
      keys = new Set<string>();
    this.ws();
    if (this.s[this.i] === "}") {
      this.i++;
      return o;
    }
    while (true) {
      this.ws();
      if (this.s[this.i] !== '"') throw new Error("invalid key");
      const k = this.str();
      if (keys.has(k)) throw new Error("duplicate JSON key");
      keys.add(k);
      this.ws();
      if (this.s[this.i++] !== ":") throw new Error("invalid object");
      o[k] = this.value();
      this.ws();
      if (this.s[this.i] === "}") {
        this.i++;
        return o;
      }
      if (this.s[this.i++] !== ",") throw new Error("invalid object");
    }
  }
}
export function parseCanonicalJson(bytes: Buffer, manifest = false): JsonValue {
  if (bytes.subarray(0, 3).equals(Buffer.from([239, 187, 191]))) throw new Error("JSON BOM");
  const s = decoder.decode(bytes);
  return new Reader(s, 0, manifest).parse();
}
function canon(v: JsonValue): string {
  if (v === null || typeof v === "boolean" || typeof v === "number") return String(v);
  if (typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canon).join(",")}]`;
  return `{${Object.keys(v)
    .sort()
    .map((k) => `${JSON.stringify(k)}:${canon(v[k]!)}`)
    .join(",")}}`;
}
export function canonicalJsonBytes(v: JsonValue) {
  return Buffer.from(canon(v));
}

export interface Manifest {
  manifestVersion: "2.0";
  adapterId: string;
  adapterVersion: string;
  minimumAppVersion: string;
  payload: { kind: "source"; entry: string } | { kind: "bytecode-only"; variants: Record<string, string> };
  capabilities: Array<Record<string, JsonValue>>;
  files: Array<{
    path: string;
    role: "manifest" | "source" | "bytecode" | "resource";
    encoding: "jcs" | "utf8" | "binary";
  }>;
}
const idRe = /^[a-z0-9]+(?:[.-][a-z0-9]+)*(?:\.[a-z0-9]+(?:[.-][a-z0-9]+)*)+$/;
export function validateManifest(v: JsonValue): Manifest {
  if (!v || typeof v !== "object" || Array.isArray(v)) throw new Error("manifest object required");
  const m = v as Record<string, JsonValue>,
    p = m.payload as Record<string, JsonValue>;
  if (
    m.manifestVersion !== "2.0" ||
    typeof m.adapterId !== "string" ||
    !idRe.test(m.adapterId) ||
    typeof m.adapterVersion !== "string" ||
    typeof m.minimumAppVersion !== "string" ||
    !p ||
    Array.isArray(p) ||
    !Array.isArray(m.capabilities) ||
    !Array.isArray(m.files) ||
    !m.capabilities.every((cap) => {
      if (!cap || typeof cap !== "object" || Array.isArray(cap)) return false;
      const c = cap as Record<string, JsonValue>,
        emits = c.emits;
      if (
        typeof c.id !== "string" ||
        !emits ||
        typeof emits !== "object" ||
        Array.isArray(emits) ||
        typeof (emits as Record<string, JsonValue>).schema !== "string" ||
        typeof (emits as Record<string, JsonValue>).version !== "string"
      )
        return false;
      const params = c.params;
      return (
        params === undefined ||
        (!!params &&
          typeof params === "object" &&
          !Array.isArray(params) &&
          typeof (params as Record<string, JsonValue>).schema === "string" &&
          typeof (params as Record<string, JsonValue>).version === "string")
      );
    }) ||
    !m.files.every((file) => {
      if (!file || typeof file !== "object" || Array.isArray(file)) return false;
      const f = file as Record<string, JsonValue>;
      return (
        typeof f.path === "string" &&
        f.path !== "META-INF/signature.json" &&
        ["manifest", "source", "bytecode", "resource"].includes(String(f.role)) &&
        ["jcs", "utf8", "binary"].includes(String(f.encoding))
      );
    })
  )
    throw new Error("invalid manifest");
  if (
    p.kind === "source"
      ? typeof p.entry === "string"
      : p.kind === "bytecode-only" &&
        p.variants &&
        typeof p.variants === "object" &&
        !Array.isArray(p.variants) &&
        Object.values(p.variants).every((x) => typeof x === "string")
  )
    return v as unknown as Manifest;
  throw new Error("invalid payload");
}

function role(path: string) {
  if (path === "manifest.json") return "manifest";
  if (path === "META-INF/signature.json") return "signature";
  if (path.startsWith("payload/source/")) return "source";
  if (path.startsWith("payload/bytecode/") && path.endsWith(".qbc")) return "bytecode";
  if (path.startsWith("resources/")) return "resource";
  throw new Error("unknown ELeB path");
}
export function contentDigest(entries: readonly (ZipEntry | ParsedZipEntry)[], manifest: Manifest) {
  const xs = entries
    .filter((x) => x.path !== "META-INF/signature.json")
    .map((x) => {
      const r = role(x.path),
        data = x.path === "manifest.json" ? canonicalJsonBytes(manifest as unknown as JsonValue) : x.data;
      return { p: pathBytes(x.path), r, data };
    })
    .sort((a, b) => Buffer.compare(a.p, b.p));
  const h = createHash("sha256");
  h.update("elecon-eleb-content\0v1\0", "ascii");
  for (const x of xs) {
    const n = Buffer.alloc(4);
    n.writeUInt32BE(x.p.length);
    h.update(n);
    h.update(x.p);
    h.update(
      Buffer.from([rCode(x.r), x.r === "manifest" ? 1 : x.r === "source" ? 2 : x.r === "signature" ? 0 : 3]),
    );
    const l = Buffer.alloc(8);
    l.writeBigUInt64BE(BigInt(x.data.length));
    h.update(l);
    h.update(x.data);
  }
  return h.digest("hex");
}
const rCode = (r: string) =>
  (({ manifest: 1, source: 2, bytecode: 3, resource: 4 }) as Record<string, number>)[r]!;

export interface SignatureV1 {
  signatureFormat: "elecon-eleb-signature/1";
  algorithm: "ed25519";
  digestAlgorithm: "sha256-v1";
  contentDigest: string;
  publicKey: string;
  signerFingerprint: string;
  keyId?: string;
  signature: string;
}
export function signaturePayload(
  s: Pick<
    SignatureV1,
    "signatureFormat" | "algorithm" | "digestAlgorithm" | "contentDigest" | "signerFingerprint"
  >,
) {
  const parts = [s.signatureFormat, s.algorithm, s.digestAlgorithm].map((x) => Buffer.from(x)),
    out = [Buffer.from("elecon-eleb-signature\0v1\0", "ascii")];
  for (const p of parts) {
    const n = Buffer.alloc(4);
    n.writeUInt32BE(p.length);
    out.push(n, p);
  }
  return Buffer.concat([
    ...out,
    Buffer.from(s.contentDigest, "hex"),
    Buffer.from(s.signerFingerprint, "hex"),
  ]);
}
export function validateSignature(v: JsonValue): SignatureV1 {
  const s = v as Record<string, JsonValue>;
  if (
    s?.signatureFormat !== "elecon-eleb-signature/1" ||
    s.algorithm !== "ed25519" ||
    s.digestAlgorithm !== "sha256-v1" ||
    typeof s.contentDigest !== "string" ||
    !/^[0-9a-f]{64}$/.test(s.contentDigest) ||
    typeof s.publicKey !== "string" ||
    !isCanonicalBase64(s.publicKey) ||
    typeof s.signerFingerprint !== "string" ||
    createHash("sha256").update(Buffer.from(s.publicKey, "base64")).digest("hex") !== s.signerFingerprint ||
    Buffer.from(s.publicKey, "base64").length !== 32 ||
    typeof s.signature !== "string" ||
    !isCanonicalBase64(s.signature) ||
    (s.keyId !== undefined && typeof s.keyId !== "string") ||
    Buffer.from(s.signature, "base64").length !== 64
  )
    throw new Error("invalid signature");
  return s as unknown as SignatureV1;
}
function isCanonicalBase64(value: string) {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return false;
  return Buffer.from(value, "base64").toString("base64") === value;
}
export function verifySignature(s: SignatureV1, key?: KeyObject) {
  const k =
    key ??
    createPublicKey({
      key: Buffer.concat([
        Buffer.from("302a300506032b6570032100", "hex"),
        Buffer.from(s.publicKey, "base64"),
      ]),
      format: "der",
      type: "spki",
    });
  return edVerify(null, signaturePayload(s), k, Buffer.from(s.signature, "base64"));
}

export function parseEleb(zip: Buffer) {
  const entries = parseBoundedZip(zip);
  const manifestEntry = entries.find((x) => x.path === "manifest.json");
  if (!manifestEntry) throw new Error("manifest.json missing");
  const manifest = validateManifest(parseCanonicalJson(manifestEntry.data, true));
  const declared = new Map(manifest.files.map((x) => [x.path, x]));
  if (declared.size !== manifest.files.length || !declared.has("manifest.json"))
    throw new Error("manifest files closure invalid");
  for (const entry of entries) {
    if (entry.path === "META-INF/signature.json") continue;
    const actual = role(entry.path),
      expected = declared.get(entry.path);
    const encoding = actual === "manifest" ? "jcs" : actual === "source" ? "utf8" : "binary";
    if (!expected || expected.role !== actual || expected.encoding !== encoding)
      throw new Error("manifest files closure invalid");
  }
  if (
    [...declared.keys()].some(
      (path) => path !== "META-INF/signature.json" && !entries.some((entry) => entry.path === path),
    )
  )
    throw new Error("manifest files closure invalid");
  if (manifest.payload.kind === "source") {
    const entryPath = manifest.payload.entry;
    if (!entries.some((x) => x.path === entryPath) || !entryPath.startsWith("payload/source/"))
      throw new Error("source entry missing");
    if (entries.some((x) => x.path.startsWith("payload/bytecode/")))
      throw new Error("source/bytecode are exclusive");
  } else {
    if (
      entries.some((x) => x.path.startsWith("payload/source/")) ||
      Object.values(manifest.payload.variants).some((x) => !entries.some((e) => e.path === x))
    )
      throw new Error("bytecode variants invalid");
  }
  const signatureEntry = entries.find((x) => x.path === "META-INF/signature.json");
  const signature = signatureEntry ? validateSignature(parseCanonicalJson(signatureEntry.data)) : undefined;
  const digest = contentDigest(entries, manifest);
  if (signature && signature.contentDigest !== digest) throw new Error("content digest mismatch");
  return { entries, manifest, contentDigest: digest, signature };
}
