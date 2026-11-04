# Hermes APPTunnel native bridge

Host-only application TCP tunnels for ADR-062. The shared library is named `libelecon_hermes.so`. It does not create TUN/VPN devices, OS routes, a public proxy listener, credential files, browser trace files or a background service. Only the host opens this compiled library. School scripts receive neither native functions nor raw sockets.

## Provenance and licensing

The `vendor/hermes` source is a subset of [Hermes-Atrust](https://github.com/ncc-devlab/Hermes-Atrust/tree/271a547d73c3839365a1995d1a6d72ed915e1458), commit `271a547d73c3839365a1995d1a6d72ed915e1458`, MIT. Its original `LICENSE` is retained. Source files are copied from the eight crates listed in `Cargo.toml`; CLI applications, browser integration, tracing tools, plaintext session store and its exports are excluded. The original workspace `Cargo.lock` was resolved for this smaller workspace and pinned here.

Local changes to upstream are limited to:

- `atrust-auth/src/lib.rs`: remove the plaintext file session store module/exports. The bridge has its own bounded in-memory session DTO.
- `atrust-auth/src/client.rs`: recognize both explicit invalid-session business codes (`75500002`, `10000004`) and expose a bounded SID snapshot from the current gateway cookie jar. The bridge also treats an explicit `authConfig.isLogin=0` as expired without another request; network failures, generic HTTP denials and unknown business codes remain unknown.
- `atrust-client/src/client.rs`: add `dial_tcp_pinned(host,address,port)`, matching authorization against the original hostname while encoding the already-admitted numeric destination in the tunnel handshake. There is no second DNS lookup for target dialing. Each TCP handshake uses the current jar SID, including rotation by `clientResource`; a missing/invalid live SID never falls back to the saved SID. Publishing that snapshot back to protected persistent storage remains future work.
- `hermes-transport`: add exact DER certificate SHA-256 pin verification, retaining real TLS 1.2/1.3 signature checks. The FFI accepts only normal PKI or this pin; upstream's diagnostic certificate-disable policy has no bridge input or execution path.
- `hermes-model/src/identifier.rs`: erase owned session/device/connection identifier strings when dropped, in addition to upstream key/SecretString erasure.

`THIRD_PARTY.json` records the resolved dependency graph, source versions and SPDX declarations, including test and target-specific packages. `THIRD_PARTY_NOTICES.txt` contains available license and notice texts from the resolved packages. Android/Linux normal graphs do not include EFI `r-efi`; for its multi-license declaration the MIT alternative is selected. No GPL-family license is selected. `Cargo.lock` pins sources/checksums. Ship this notice file and `vendor/hermes/LICENSE` with distributed native assets. The checked-in Flutter asset copies under `client/assets/native/hermes/` match this pinned edition; update both copies with any dependency change. Flutter bundles these paths and registers them in the in-app license page. The graph contains Rustls/ring, Tokio, Reqwest and the existing upstream crypto/serialization dependencies; no native module is obtained from a school script.

## C ABI version 1

```c
char *elecon_hermes_call(const char *input_json);
void elecon_hermes_free(char *output_json);
```

The caller supplies a live NUL-terminated UTF-8 allocation, no more than 1 MiB, and frees each result once with the paired function. Calls other than `version` and `cancel` can block and belong in a Dart worker isolate. Input copies, typed session secrets, generic JSON values and returned allocations are erased when released. The upstream HTTP cookie jar is dropped on close; this is not a claim that every allocator/platform copy can be erased.

Results have `{ "ok": true, ...fields }` or `{ "ok": false, "error": "hermes_..." }`. Errors never include source errors, URLs, cookies, IDs, keys or protocol rejection bodies. Never log RPC input/output. `version` returns `version:1`. Fixed errors are `hermes_invalid_request`, `hermes_invalid_configuration`, `hermes_authentication_required`, `hermes_connection_failed`, `hermes_dns_failed`, `hermes_not_authorized`, `hermes_cancelled`, `hermes_closed` and `hermes_internal_error`.

Each operation may include `requestId`, a fresh 32-character hexadecimal ID; the host should always supply one. `cancel` with the same ID cancels pending initialization, resolution, dialing or UDS work, including cancel-before-worker-registration. Cancel tombstones expire after 180 seconds; active work is never evicted. There are at most 1024 controls and eight sessions. Operations have a 45-second native limit; the surrounding host invocation can impose a smaller budget.

- `authenticateCookies`: `gatewayUrl` must be an exact HTTPS origin; `cookies` are the trusted gateway cookies harvested after the user completes official login/MFA. Cookie fields are `name,value,domain,path,secure,http_only`. The bridge accepts only matching browser cookie domains, tightens them to the exact HTTPS gateway scope, queries `auth_config` and `online_info`, then returns `session`. There is no password UI, automatic CAS exchange or live-login retry. Upstream creates a logical device ID and a **provisional** signing key; whether a particular gateway accepts that key remains a real-gateway acceptance item. A successful account query alone does not certify tunnel connectivity.
- `start`: `gatewayUrl`, `session` (the protected in-memory session object returned by authentication), `socketDirectory` and optional `nodeCertificateSha256` (64 hex digits). Gateway/identity are verified before starting `AtrustClient`; response contains integer `handle`. Normal PKI is the default for node TLS. A configured pin trusts exactly that certificate, and mismatch fails closed. Gateway control-plane TLS always uses normal PKI.
- `resolve`: `handle,host` returns `addresses`. Exact-host IPs from the authenticated resource table are preferred. Otherwise DNS TCP queries go through the selected Hermes connection to a resource-advertised DNS server; no OS/public target DNS fallback exists. If the gateway does not authorize its DNS server over TCP, this returns `hermes_dns_failed`. DNS replies require matching transaction/question and owner/CNAME chain, bounded compression/answers; receipt addresses are cached only within this session.
- `dial`: `handle,host,address,port` requires `address` to match a prior session resolution (or the same numeric literal). The resource table still authorizes the hostname and port. It returns one `path` to an owner-only UDS. Connect immediately; there is only one accept, the path is unlinked on accept, accept expires in 10 seconds, and the bridge has a 120-second limit. `stop`/cancel drops pending and active tunnels. HTTP and inner target TLS remain in Dart; no school HTTP plaintext is passed into FFI.
- `status`: `handle` returns `status:"ready"` for a live handle. This is runtime readiness, not connectivity to every school resource.
- `stop`: `handle` idempotently revokes the session, joins aborted UDS cleanup and shuts down the Hermes client.

The host passes its fixed app-private `ht` subdirectory. The bridge validates ownership, rejects symlink ancestors and requires owner-only permissions. A default-created `ht` directory is tightened to `0700` only when it has an already-private ancestor owned by this process. Socket files are `0600`, contain no session material and are removed when closed. No session file path is accepted.

## Builds and checks

```sh
cargo test --locked -p elecon-hermes-app-tunnel
cargo build --locked -p elecon-hermes-app-tunnel
./build-android.sh --out-dir /absolute/output --ndk-dir /path/to/android-sdk/ndk/28.2.13676358 --abis arm64-v8a
```

Android uses API 21, installed Rust targets, and an explicit NDK directory (`--ndk-dir`, or `ANDROID_NDK_HOME` for standalone builds). Gradle supplies its selected NDK through `androidComponents.sdkComponents.ndkDirectory`, so Hermes and the application use the same version. No newest-installed-NDK fallback is used. It emits `/absolute/output/arm64-v8a/libelecon_hermes.so`. `--abis` also accepts `x86_64` and `armeabi-v7a`; their Rust targets must be installed first: `rustup target add armv7-linux-androideabi aarch64-linux-android x86_64-linux-android` prepares the default Flutter APK. All requested targets are checked before any compilation; `bash build-android.test.sh` exercises this preflight without an SDK or network. The script does not download toolchains, alter global configuration or put binaries in Git. Linux debug builds emit `target/debug/libelecon_hermes.so` for actual C ABI tests. Other platforms remain unverified; the Unix bridge is not a Windows implementation.

On 2026-11-02 the eight native tests passed: fixed C ABI errors, cancel before registration, cancellation during real loopback TLS initialization, private directory handling, DNS framing/identity validation, correct/wrong certificate pins with real TLS signatures, gateway-cookie scope tightening, and an actual synthetic Hermes handshake with pinned destination plus one-shot UDS echo and cleanup. Linux and Android ARM64 libraries compiled. Test certificates/keys are synthetic fixtures reused from the client's WebSocket tests. No real gateway, school account or system VPN was accessed. These checks do not replace native/network review or real-gateway/device acceptance.

ADR-064 adds the host-only `authenticatePassword` operation. Credentials remain in the protected Profile/school store, separate from verified sessions. An explicit action runs authConfig → one encrypted password attempt → reportEnv/authCheck → onlineInfo/SID capture. Ambiguous domains, captcha and MFA stop with `hermes_interaction_required`; no credential retry or automatic web fallback occurs. Password input is never included in returned session JSON or diagnostics. The existing `authenticateCookies` web flow remains available. No additional dependencies are introduced.

ADR-066 adds host-only `checkSession` with `gatewayUrl` and a protected `session`.
It checks `auth_config` and `online_info` against the stored username, returning
`authenticated` (with an optional account label), `expired`, or `unknown`.
ADR-075 also returns a host-only refreshed session on authenticated checks. The
host validates identity/material continuity and persists the latest Cookie jar
before publishing success; SDK callers never receive that session. Deleted or
invalid live SID means unknown, never fallback to a saved SID.
Network errors stay unknown; a confirmed invalid session or account mismatch is
expired. It does not open a tunnel or submit a password. SDK 12 scripts receive
this reduced account state through the declared APPTunnel port, never the native
request, stored session, or credentials. Authentication publication revokes the
old script invocation; the native login page rechecks in the new generation.

The [2026-11-03 ZJU Connect comparison](../../docs/research/hermes_zju_connect_alignment.md)
records protocol differences, licensing boundaries and the remaining gateway
acceptance work. Bridge tests cover the updated account-state behavior;
they do not establish complete protocol parity or real gateway connectivity.
