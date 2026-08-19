# 公网端点 D —— adapter 分发（静态、零凭证、可 CDN）

端点 D 只做一件事：把**预先构建、已签名**的静态产物按原样发出去。它**不签名、不验签、不读
adapter 源、无状态、零凭证**（红线 #2）。完整性由**客户端**对 app 内 pin 公钥验签保证
> 本目录描述当前 V1 migration baseline。ADR-005/006 落地后，signed catalog 将由非权威 discovery index 取代，执行信任直接来自自包含 `.eleb`；独立 revocation 保留。

（ADR-002 §2.3/§2.6，ADR-018 §2.9）——**端点被投毒也无法提权**：篡改的 bundle/catalog 在
客户端验签 fail-closed。故本端点可无差别替换为任意静态托管 / CDN / 对象存储。

> 任意贡献者都能自建镜像端点：因为它只是"发一棵静态目录"，无任何私密/状态。

## 分发结构（`dist/` 静态根）

```
dist/
  catalog.json.gz            签名 catalog（gzip-JSON；ADR-018 §2.5）        —— 短缓存
  revocation.json            签名吊销清单（ADR-002 §2.4）                  —— 短缓存
  bundles/
    <digest>.json.gz         内容寻址签名 bundle（gzip-JSON；§2.9）        —— immutable 长缓存
```

- `<digest>` = bundle 规范化双层 SHA-256（catalog 的 `entry.digest` / `entry.url` 指向此文件）。
- **不含公钥**：pin 公钥预埋在 app 内，绝不由端点下发（ADR-002 §2.3）。
- **零状态 / 零凭证**：只读 `dist/`；忽略且不记录 Cookie/Authorization。
- `dist/` 由**核心签名管线**产出（🔒，在核心侧，另行落地）——端点不参与生成。

## 缓存策略

| 路径 | `Cache-Control` | 理由 |
|---|---|---|
| `/bundles/<digest>.json.gz` | `public, max-age=31536000, immutable` | 内容寻址，永不变，可永久缓存 |
| `/catalog.json.gz`、`/revocation.json` | `public, max-age=60` | 新鲜度靠内部 `sequence`/TTL，短缓存即可 |

`.json.gz` 以 `application/gzip` **原样字节**发出（客户端自行 gunzip，见 ADR-018 §2.9）——
**不要**设 `Content-Encoding: gzip`（否则中间层会自动解压，破坏客户端的字节级验签）。

## 部署（任选其一）

### A. Docker（nginx，推荐）
```bash
docker build -t elecon-endpoint deploy/public-endpoint
docker run --rm -p 8080:80 -v /abs/path/to/dist:/srv/dist:ro elecon-endpoint
# 验证：curl -sI http://localhost:8080/catalog.json.gz
```

### B. 任意静态托管 / CDN / 对象存储
把整个 `dist/` 上传到 S3 / Cloudflare R2·Pages / GitHub Pages / nginx / caddy，按上表配缓存头即可。
端点无状态、天然可放 CDN。

### C. Node 参考实现（dev / 自测）
```bash
cd server && PUBLIC_DIST_DIR=/abs/path/to/dist npm run start:public
```
`server/src/public/index.ts`：零依赖（node builtins），含路径穿越守卫 + 上述缓存策略；
生产建议前置 CDN。冒烟：`cd server && npm run smoke:public`。
