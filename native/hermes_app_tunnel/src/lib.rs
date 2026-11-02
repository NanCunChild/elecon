//! Host-only Hermes adapter. No TUN, global routes, public proxy, session files,
//! school HTTP headers or HTTP response bodies cross this interface.
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr, CString};
use std::net::IpAddr;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use atrust_auth::{
    extract_sid_from_cookies, AuthClient, AuthConfigOptions, AuthConfiguration, CasExchange,
    FlowProtocol, PasswordCredentials, SessionMaterial, SessionProgress,
};
use atrust_client::{AtrustClient, AtrustClientConfig};
use hermes_model::{ConnectionId, DeviceId, GatewayEndpoint, SecretString, SessionId, SignKey};
use hermes_transport::{
    GatewayCookie, HttpTransport, ReqwestTransport, ReqwestTransportConfig, TlsPolicy,
};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::net::UnixListener;
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{watch, OwnedSemaphorePermit, Semaphore};
use tokio::task::JoinHandle;
use zeroize::{Zeroize, Zeroizing};

mod dns;
type Result<T> = std::result::Result<T, &'static str>;
const INVALID: &str = "hermes_invalid_request";
const CONFIG: &str = "hermes_invalid_configuration";
const AUTH: &str = "hermes_authentication_required";
const INTERACTION: &str = "hermes_interaction_required";
const CONNECT: &str = "hermes_connection_failed";
const CANCELLED: &str = "hermes_cancelled";
const CLOSED: &str = "hermes_closed";
const INTERNAL: &str = "hermes_internal_error";
const MAX_JSON: usize = 1024 * 1024;
static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
    Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("Hermes runtime")
});
static SESSIONS: LazyLock<Mutex<HashMap<u64, Arc<Session>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static REQUESTS: LazyLock<Mutex<HashMap<String, Arc<Control>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static SESSION_SLOTS: LazyLock<Arc<Semaphore>> = LazyLock::new(|| Arc::new(Semaphore::new(8)));

struct Control {
    cancel: watch::Sender<bool>,
    used: AtomicBool,
    created: Instant,
    keep: AtomicBool,
    active: AtomicBool,
}
impl Control {
    fn new() -> Self {
        let (cancel, _) = watch::channel(false);
        Self {
            cancel,
            used: AtomicBool::new(false),
            created: Instant::now(),
            keep: AtomicBool::new(false),
            active: AtomicBool::new(false),
        }
    }
}
struct Session {
    client: Arc<AtrustClient>,
    directory: PathBuf,
    stopped: watch::Sender<bool>,
    bridges: Mutex<Vec<JoinHandle<()>>>,
    // Cache is bounded and only accepts answers from resource records/tunnel DNS.
    resolved: Mutex<HashMap<String, Vec<IpAddr>>>,
    _slot: OwnedSemaphorePermit,
}
impl Session {
    fn active(&self) -> Result<()> {
        if *self.stopped.borrow() {
            Err(CLOSED)
        } else {
            Ok(())
        }
    }
}

/// C ABI. Invoke blocking operations from a Dart worker isolate. Never log input/output.
///
/// # Safety
/// `input` must point to a live NUL-terminated UTF-8 allocation owned by the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elecon_hermes_call(input: *const c_char) -> *mut c_char {
    let response = std::panic::catch_unwind(|| {
        if input.is_null() {
            return json!({"ok":false,"error":INVALID});
        }
        // SAFETY: the host C ABI requires a live NUL-terminated allocation.
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        if bytes.len() > MAX_JSON {
            return json!({"ok":false,"error":INVALID});
        }
        let raw = Zeroizing::new(bytes.to_vec());
        let request: Value = match serde_json::from_slice(&raw) {
            Ok(v) => v,
            Err(_) => return json!({"ok":false,"error":INVALID}),
        };
        match call(request) {
            Ok(mut result) => {
                result["ok"] = json!(true);
                result
            }
            Err(error) => json!({"ok":false,"error":error}),
        }
    })
    .unwrap_or_else(|_| json!({"ok":false,"error":INTERNAL}));
    let encoded = response.to_string();
    let mut response = response;
    erase_json(&mut response);
    CString::new(encoded).unwrap_or_default().into_raw()
}

/// Free exactly one returned allocation; this also erases response secrets.
///
/// # Safety
/// `value` must be null or an unfreed pointer returned by `elecon_hermes_call`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn elecon_hermes_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: only pointers returned by elecon_hermes_call may be passed.
        let allocated = unsafe { CString::from_raw(value) };
        let mut bytes = allocated.into_bytes_with_nul();
        bytes.zeroize();
    }
}

fn control(id: &str) -> Result<Arc<Control>> {
    if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(INVALID);
    }
    let mut requests = REQUESTS.lock().map_err(|_| INTERNAL)?;
    requests.retain(|_, value| {
        value.active.load(Ordering::SeqCst) || value.created.elapsed() < Duration::from_secs(180)
    });
    if requests.len() >= 1024 && !requests.contains_key(id) {
        return Err(INVALID);
    }
    Ok(requests
        .entry(id.to_owned())
        .or_insert_with(|| Arc::new(Control::new()))
        .clone())
}

struct SensitiveJson(Value);
impl std::ops::Deref for SensitiveJson {
    type Target = Value;
    fn deref(&self) -> &Value {
        &self.0
    }
}
impl std::ops::DerefMut for SensitiveJson {
    fn deref_mut(&mut self) -> &mut Value {
        &mut self.0
    }
}
impl Drop for SensitiveJson {
    fn drop(&mut self) {
        erase_json(&mut self.0);
    }
}

fn call(request: Value) -> Result<Value> {
    let mut request = SensitiveJson(request);
    let op = request
        .get("op")
        .and_then(Value::as_str)
        .ok_or(INVALID)?
        .to_owned();
    if op == "version" {
        return Ok(json!({"version":1}));
    }
    if op == "cancel" {
        let id = string(&request, "requestId", 32)?;
        control(id)?.cancel.send_replace(true);
        return Ok(json!({}));
    }
    let owned_id = request
        .get("requestId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(random_id);
    let signal = control(&owned_id)?;
    if signal.used.swap(true, Ordering::SeqCst) {
        return Err(INVALID);
    }
    if *signal.cancel.borrow() {
        return Err(CANCELLED);
    }
    signal.active.store(true, Ordering::SeqCst);
    // Move secrets into typed structures below, then erase the generic JSON tree.
    let outcome = RUNTIME.block_on(async {
        let mut cancelled = signal.cancel.subscribe();
        if *cancelled.borrow() { return Err(CANCELLED); }
        let work = async {
            match op.as_str() {
                "authenticateCookies" => authenticate(&mut request).await,
                "authenticatePassword" => authenticate_password(&mut request).await,
                "start" => start(&mut request).await,
                "checkSession" => check_session(&mut request).await,
                "resolve" | "dial" => {
                    let session = session(&request)?;
                    let mut stopped = session.stopped.subscribe();
                    session.active()?;
                    tokio::select! {
                        biased;
                        _ = stopped.changed() => Err(CLOSED),
                        result = async {
                            if op == "resolve" { resolve(&session, &request).await }
                            else { dial(&session, &request, signal.clone()).await }
                        } => result,
                    }
                }
                "stop" => stop(&request).await,
                "status" => { session(&request)?.active()?; Ok(json!({"status":"ready"})) },
                _ => Err(INVALID),
            }
        };
        tokio::select! {
            biased;
            _ = cancelled.changed() => Err(CANCELLED),
            result = tokio::time::timeout(Duration::from_secs(45), work) => result.unwrap_or(Err(CONNECT)),
        }
    });
    erase_json(&mut request);
    // Keep a cancelled tombstone briefly so cancel-before-worker-start is safe.
    signal.active.store(false, Ordering::SeqCst);
    if !*signal.cancel.borrow() && !signal.keep.load(Ordering::SeqCst) {
        REQUESTS.lock().map_err(|_| INTERNAL)?.remove(&owned_id);
    }
    outcome
}

fn erase_json(value: &mut Value) {
    match value {
        Value::String(s) => s.zeroize(),
        Value::Array(a) => a.iter_mut().for_each(erase_json),
        Value::Object(o) => o.values_mut().for_each(erase_json),
        _ => {}
    }
}
fn random_id() -> String {
    let mut value = [0u8; 16];
    rand::rng().fill_bytes(&mut value);
    hex::encode(value)
}
fn string<'a>(value: &'a Value, key: &str, limit: usize) -> Result<&'a str> {
    value
        .get(key)
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty() && s.len() <= limit)
        .ok_or(INVALID)
}
fn gateway(value: &Value) -> Result<(GatewayEndpoint, url::Url)> {
    let url = url::Url::parse(string(value, "gatewayUrl", 2048)?).map_err(|_| CONFIG)?;
    if url.scheme() != "https"
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || url.path() != "/"
    {
        return Err(CONFIG);
    }
    let host = url.host_str().ok_or(CONFIG)?;
    Ok((
        GatewayEndpoint::new(host, url.port_or_known_default().ok_or(CONFIG)?)
            .map_err(|_| CONFIG)?,
        url,
    ))
}
fn session(value: &Value) -> Result<Arc<Session>> {
    let handle = value.get("handle").and_then(Value::as_u64).ok_or(INVALID)?;
    SESSIONS
        .lock()
        .map_err(|_| INTERNAL)?
        .get(&handle)
        .cloned()
        .ok_or(CLOSED)
}
fn transport(gateway: &GatewayEndpoint, cookies: &[Cookie]) -> Result<Arc<ReqwestTransport>> {
    let transport =
        Arc::new(ReqwestTransport::new(&ReqwestTransportConfig::default()).map_err(|_| CONFIG)?);
    let origin = url::Url::parse(&format!("https://{gateway}/")).map_err(|_| CONFIG)?;
    let imported = cookies
        .iter()
        .map(|cookie| {
            let mut scoped = cookie.gateway();
            // Browser cookies may cover a parent domain or omit Secure. The native
            // control-plane client only needs the exact HTTPS gateway origin.
            scoped.domain = Some(gateway.host().to_owned());
            scoped.secure = true;
            scoped
        })
        .collect::<Vec<_>>();
    transport
        .import_gateway_cookies(&origin, &imported)
        .map_err(|_| CONFIG)?;
    Ok(transport)
}

#[derive(Deserialize, Serialize)]
struct Cookie {
    name: String,
    value: String,
    domain: Option<String>,
    path: Option<String>,
    #[serde(default = "yes")]
    secure: bool,
    #[serde(default = "yes")]
    http_only: bool,
}
fn yes() -> bool {
    true
}
impl Drop for Cookie {
    fn drop(&mut self) {
        self.value.zeroize();
    }
}
impl Cookie {
    fn gateway(&self) -> GatewayCookie {
        GatewayCookie {
            name: self.name.clone(),
            value: self.value.clone(),
            domain: self.domain.clone(),
            path: self.path.clone(),
            secure: self.secure,
            http_only: self.http_only,
        }
    }
}
#[derive(Deserialize, Serialize)]
struct Stored {
    version: u32,
    saved_unix_ms: u128,
    gateway_host: String,
    gateway_port: u16,
    login_method: String,
    login_domain: Option<String>,
    cookies: Vec<Cookie>,
    sid: String,
    sid_cookie_name: String,
    sid_sig_present: bool,
    device_id: String,
    connection_id: String,
    sign_key_hex: String,
    sign_key_provisional: bool,
    username: Option<String>,
}
impl Drop for Stored {
    fn drop(&mut self) {
        self.sid.zeroize();
        self.device_id.zeroize();
        self.connection_id.zeroize();
        self.sign_key_hex.zeroize();
        if let Some(s) = &mut self.username {
            s.zeroize();
        }
    }
}
impl Stored {
    fn validate(&self, gateway: &GatewayEndpoint) -> Result<()> {
        if self.version != 1
            || !self.gateway_host.eq_ignore_ascii_case(gateway.host())
            || self.gateway_port != gateway.port()
            || self.sid.len() > 16384
            || self.device_id.len() > 512
            || self.connection_id.len() > 512
            || self.sign_key_hex.len() != 64
            || self.cookies.len() > 256
            || self.username.as_ref().is_some_and(|s| s.len() > 512)
        {
            return Err(CONFIG);
        }
        for c in &self.cookies {
            if c.name.len() > 128
                || c.value.len() > 16384
                || c.domain.as_ref().is_some_and(|s| {
                    let domain = s.trim_start_matches('.').to_ascii_lowercase();
                    let host = gateway.host().to_ascii_lowercase();
                    domain.is_empty() || !(host == domain || host.ends_with(&format!(".{domain}")))
                })
                || c.path
                    .as_ref()
                    .is_some_and(|s| !s.starts_with('/') || s.len() > 2048)
            {
                return Err(CONFIG);
            }
        }
        Ok(())
    }
    fn material(&self) -> Result<SessionMaterial> {
        Ok(SessionMaterial::from_parts(
            SessionId::new(self.sid.clone()).map_err(|_| CONFIG)?,
            DeviceId::new(self.device_id.clone()).map_err(|_| CONFIG)?,
            ConnectionId::new(self.connection_id.clone()).map_err(|_| CONFIG)?,
            SignKey::from_hex(&self.sign_key_hex).map_err(|_| CONFIG)?,
            self.username.clone(),
            self.sign_key_provisional,
            self.sid_cookie_name.clone(),
            self.sid_sig_present,
        ))
    }
}
async fn authenticate(value: &mut Value) -> Result<Value> {
    let (gateway, origin) = gateway(value)?;
    let cookies: Vec<Cookie> =
        serde_json::from_value(value.get_mut("cookies").ok_or(INVALID)?.take())
            .map_err(|_| INVALID)?;
    // Validate shape and exact gateway scope before any request.
    let probe = Stored {
        version: 1,
        saved_unix_ms: 0,
        gateway_host: gateway.host().to_owned(),
        gateway_port: gateway.port(),
        login_method: "cas".into(),
        login_domain: None,
        cookies,
        sid: "placeholder".into(),
        sid_cookie_name: "sid".into(),
        sid_sig_present: false,
        device_id: "placeholder".into(),
        connection_id: "placeholder".into(),
        sign_key_hex: "00".repeat(32),
        sign_key_provisional: true,
        username: None,
    };
    probe.validate(&gateway)?;
    let transport = transport(&gateway, &probe.cookies)?;
    let auth = AuthClient::new(gateway.clone(), transport.clone());
    let configuration = auth
        .auth_config(AuthConfigOptions {
            modified: true,
            need_ticket: false,
        })
        .await
        .map_err(|_| AUTH)?;
    capture_session(
        &gateway,
        &origin,
        transport.as_ref(),
        &auth,
        &configuration,
        DeviceId::new(random_id()).map_err(|_| CONFIG)?,
        LoginMethod::Browser,
    )
    .await
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PasswordInput {
    username: String,
    password: String,
    #[serde(default)]
    login_domain: String,
}
impl Drop for PasswordInput {
    fn drop(&mut self) {
        self.username.zeroize();
        self.password.zeroize();
        self.login_domain.zeroize();
    }
}
async fn authenticate_password(value: &mut Value) -> Result<Value> {
    let (gateway, origin) = gateway(value)?;
    let input: PasswordInput = serde_json::from_value(value.take()).map_err(|_| INVALID)?;
    if input.username.is_empty()
        || input.username.len() > 1024
        || input.username.chars().any(char::is_control)
        || input.login_domain.len() > 1024
        || input.login_domain.chars().any(char::is_control)
        || input.password.is_empty()
        || input.password.len() > 16384
        || input.password.contains('\0')
    {
        return Err(CONFIG);
    }
    let transport = transport(&gateway, &[])?;
    let auth = AuthClient::new(gateway.clone(), transport.clone());
    let configuration = auth
        .auth_config(AuthConfigOptions {
            modified: true,
            need_ticket: false,
        })
        .await
        .map_err(|_| AUTH)?;
    let device = DeviceId::new(random_id()).map_err(|_| CONFIG)?;
    let domain = password_step(&auth, &configuration, &input, &device).await?;
    capture_session(
        &gateway,
        &origin,
        transport.as_ref(),
        &auth,
        &configuration,
        device,
        LoginMethod::Password(domain),
    )
    .await
}

/// One primary attempt. No credential retry or automatic interactive fallback.
async fn password_step(
    auth: &AuthClient,
    configuration: &AuthConfiguration,
    input: &PasswordInput,
    device: &DeviceId,
) -> Result<String> {
    let domains: HashSet<_> = configuration
        .methods
        .iter()
        .filter(|m| m.auth_type == "auth/psw")
        .map(|m| m.login_domain.as_str())
        .collect();
    let domain = if input.login_domain.is_empty() {
        if domains.len() != 1 {
            return Err(INTERACTION);
        }
        *domains.iter().next().ok_or(INTERACTION)?
    } else {
        if !domains.contains(input.login_domain.as_str()) {
            return Err(INTERACTION);
        }
        input.login_domain.as_str()
    };
    let credentials = PasswordCredentials::new(
        &input.username,
        SecretString::new(input.password.clone()).map_err(|_| CONFIG)?,
        domain,
    )
    .map_err(|_| CONFIG)?;
    let outcome = auth
        .authenticate_password(configuration, &credentials, device, None)
        .await
        .map_err(|_| AUTH)?;
    if outcome.captcha_required {
        return Err(INTERACTION);
    }
    let exchange = CasExchange {
        portal_ticket: outcome.ticket.ok_or(AUTH)?,
    };
    match auth
        .establish_session_from_portal(configuration, &exchange, device)
        .await
        .map_err(|_| AUTH)?
    {
        SessionProgress::Established { .. } => Ok(domain.to_owned()),
        SessionProgress::InteractionRequired { .. } => Err(INTERACTION),
    }
}

enum LoginMethod {
    Browser,
    Password(String),
}

async fn capture_session(
    gateway: &GatewayEndpoint,
    origin: &url::Url,
    transport: &dyn HttpTransport,
    auth: &AuthClient,
    configuration: &AuthConfiguration,
    device: DeviceId,
    login: LoginMethod,
) -> Result<Value> {
    let username = auth.online_info(configuration).await.map_err(|_| AUTH)?;
    let cookies = transport.session_cookies(origin);
    let source = extract_sid_from_cookies(&cookies).map_err(|_| AUTH)?;
    let material = SessionMaterial::from_cookie_sid(
        &source.value,
        source.cookie_name,
        source.sid_sig_present,
        device,
        Some(username),
        None,
    )
    .map_err(|_| AUTH)?;
    let (method, domain) = match login {
        LoginMethod::Browser => ("cas", None),
        LoginMethod::Password(domain) => ("password", Some(domain)),
    };
    let stored = Stored {
        version: 1,
        saved_unix_ms: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| INTERNAL)?
            .as_millis(),
        gateway_host: gateway.host().to_owned(),
        gateway_port: gateway.port(),
        login_method: method.into(),
        login_domain: domain,
        cookies: cookies
            .iter()
            .map(|c| Cookie {
                name: c.name.clone(),
                value: c.value.clone(),
                domain: c.domain.clone(),
                path: c.path.clone(),
                secure: c.secure,
                http_only: c.http_only,
            })
            .collect(),
        sid: material.sid.as_str().into(),
        sid_cookie_name: material.sid_cookie_name.clone(),
        sid_sig_present: material.sid_sig_present,
        device_id: material.device_id.as_str().into(),
        connection_id: material.connection_id.as_str().into(),
        sign_key_hex: material.sign_key.to_hex_lower(),
        sign_key_provisional: material.sign_key_provisional,
        username: material.username.clone(),
    };
    Ok(json!({"session":stored}))
}
// Read-only online proof. Transport/protocol errors remain unknown; only an
// explicit invalid-session response or different identity proves expiration.
async fn check_session(value: &mut Value) -> Result<Value> {
    let (gateway, _) = gateway(value)?;
    let stored: Stored = serde_json::from_value(value.get_mut("session").ok_or(INVALID)?.take())
        .map_err(|_| CONFIG)?;
    stored.validate(&gateway)?;
    let auth = AuthClient::new(gateway.clone(), transport(&gateway, &stored.cookies)?);
    let configuration = match auth
        .auth_config(AuthConfigOptions {
            modified: true,
            need_ticket: false,
        })
        .await
    {
        Ok(config) => config,
        Err(error) if error.is_session_invalid() => return Ok(json!({"status":"expired"})),
        Err(_) => return Ok(json!({"status":"unknown"})),
    };
    Ok(online_account_state(&auth, &configuration, stored.username.as_deref()).await)
}
async fn online_account_state(
    auth: &AuthClient,
    configuration: &AuthConfiguration,
    expected: Option<&str>,
) -> Value {
    match auth.online_info(configuration).await {
        Ok(username) if expected == Some(username.as_str()) => {
            json!({"status":"authenticated", "accountLabel":username})
        }
        Ok(_) => json!({"status":"expired"}),
        Err(error) if error.is_session_invalid() => json!({"status":"expired"}),
        Err(_) => json!({"status":"unknown"}),
    }
}
async fn start(value: &mut Value) -> Result<Value> {
    let (gateway, _) = gateway(value)?;
    let stored: Stored = serde_json::from_value(value.get_mut("session").ok_or(INVALID)?.take())
        .map_err(|_| CONFIG)?;
    stored.validate(&gateway)?;
    let directory = private_directory(string(value, "socketDirectory", 90)?)?;
    let policy = match value.get("nodeCertificateSha256") {
        None | Some(Value::Null) => TlsPolicy::Verify,
        Some(Value::String(pin)) if pin.len() == 64 => {
            let bytes = hex::decode(pin).map_err(|_| CONFIG)?;
            TlsPolicy::PinnedCertificateSha256(bytes.try_into().map_err(|_| CONFIG)?)
        }
        _ => return Err(CONFIG),
    };
    // Reserve before any async work; concurrent starts share the same bound.
    let slot = SESSION_SLOTS
        .clone()
        .try_acquire_owned()
        .map_err(|_| CONFIG)?;
    let transport = transport(&gateway, &stored.cookies)?;
    let auth = Arc::new(AuthClient::new(gateway.clone(), transport));
    let configuration = auth
        .auth_config(AuthConfigOptions {
            modified: true,
            need_ticket: false,
        })
        .await
        .map_err(|_| AUTH)?;
    let username = auth.online_info(&configuration).await.map_err(|_| AUTH)?;
    if stored.username.as_deref() != Some(username.as_str()) {
        return Err(AUTH);
    }
    let client = AtrustClient::start(
        auth,
        configuration,
        stored.material()?,
        AtrustClientConfig::new(gateway, policy),
    )
    .await
    .map_err(|_| CONNECT)?;
    let (stopped, _) = watch::channel(false);
    let session = Arc::new(Session {
        client,
        directory,
        stopped,
        bridges: Mutex::new(vec![]),
        resolved: Mutex::new(HashMap::new()),
        _slot: slot,
    });
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    SESSIONS
        .lock()
        .map_err(|_| INTERNAL)?
        .insert(handle, session);
    Ok(json!({"handle":handle}))
}
fn private_directory(raw: &str) -> Result<PathBuf> {
    let path = PathBuf::from(raw);
    if !path.is_absolute()
        || path
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(CONFIG);
    }
    let meta = std::fs::symlink_metadata(&path).map_err(|_| CONFIG)?;
    // The host passes its fixed app-private ht directory. A default Dart
    // mkdir can produce 0755; tighten it only under an already-private ancestor
    // owned by this process. No arbitrary directory creation or symlink walk.
    let uid = unsafe { libc::geteuid() };
    if !meta.is_dir() || meta.file_type().is_symlink() || meta.uid() != uid {
        return Err(CONFIG);
    }
    let mut private_ancestor = false;
    for ancestor in path.ancestors().skip(1) {
        let entry = std::fs::symlink_metadata(ancestor).map_err(|_| CONFIG)?;
        if !entry.is_dir() || entry.file_type().is_symlink() {
            return Err(CONFIG);
        }
        if entry.uid() == uid && entry.permissions().mode() & 0o077 == 0 {
            private_ancestor = true;
        }
    }
    if meta.permissions().mode() & 0o077 != 0 {
        if path.file_name().and_then(|s| s.to_str()) != Some("ht") || !private_ancestor {
            return Err(CONFIG);
        }
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
            .map_err(|_| CONFIG)?;
    }
    Ok(path)
}
fn host(value: &Value) -> Result<&str> {
    let h = string(value, "host", 253)?;
    if h.parse::<IpAddr>().is_ok() {
        return Ok(h);
    }
    if h.ends_with('.')
        || !h.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        })
    {
        return Err(INVALID);
    }
    Ok(h)
}
async fn resolve(session: &Session, value: &Value) -> Result<Value> {
    session.active()?;
    let host = host(value)?;
    let addresses = if let Ok(ip) = host.parse::<IpAddr>() {
        vec![ip]
    } else {
        let resources = session.client.resources().await;
        let mut addresses = resources
            .resources()
            .domain_resources
            .iter()
            .filter(|r| r.host.eq_ignore_ascii_case(host))
            .flat_map(|r| r.resolved_ips.iter().copied().map(IpAddr::V4))
            .collect::<Vec<_>>();
        if addresses.is_empty() {
            addresses = dns::resolve(&session.client, &resources.resources().dns, host).await?;
        }
        addresses
    };
    let mut unique = HashSet::new();
    let addresses = addresses
        .into_iter()
        .filter(|a| unique.insert(*a))
        .take(32)
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        return Err("hermes_dns_failed");
    }
    let mut cache = session.resolved.lock().map_err(|_| INTERNAL)?;
    if cache.len() >= 128 && !cache.contains_key(host) {
        return Err("hermes_dns_failed");
    }
    cache.insert(host.to_owned(), addresses.clone());
    Ok(json!({"addresses":addresses.iter().map(ToString::to_string).collect::<Vec<_>>()}))
}
struct SocketPath(PathBuf);
impl Drop for SocketPath {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}
async fn dial(session: &Arc<Session>, value: &Value, signal: Arc<Control>) -> Result<Value> {
    session.active()?;
    let host = host(value)?;
    let address: IpAddr = string(value, "address", 80)?.parse().map_err(|_| INVALID)?;
    let port = value
        .get("port")
        .and_then(Value::as_u64)
        .filter(|p| *p > 0 && *p <= 65535)
        .ok_or(INVALID)? as u16;
    let admitted = host.parse::<IpAddr>().ok() == Some(address)
        || session
            .resolved
            .lock()
            .map_err(|_| INTERNAL)?
            .get(host)
            .is_some_and(|values| values.contains(&address));
    if !admitted
        || session
            .client
            .route(host, port, FlowProtocol::Tcp)
            .await
            .is_none()
    {
        return Err("hermes_not_authorized");
    }
    {
        let mut bridges = session.bridges.lock().map_err(|_| INTERNAL)?;
        bridges.retain(|task| !task.is_finished());
        if bridges.len() >= 32 {
            return Err(CONNECT);
        }
    }
    let mut tunnel = session
        .client
        .dial_tcp_pinned(host, &address.to_string(), port)
        .await
        .map_err(|_| CONNECT)?
        .tunnel;
    session.active()?;
    let path = session.directory.join(format!("h-{}", &random_id()[..16]));
    if path.as_os_str().len() > 103 {
        return Err(CONFIG);
    }
    let listener = UnixListener::bind(&path).map_err(|_| CONNECT)?;
    let guard = SocketPath(path.clone());
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).map_err(|_| CONNECT)?;
    let mut cancelled = signal.cancel.subscribe();
    let mut stopped = session.stopped.subscribe();
    signal.keep.store(true, Ordering::SeqCst);
    let task = tokio::spawn(async move {
        let _guard = guard;
        let _request_guard = signal;
        if *cancelled.borrow() || *stopped.borrow() {
            return;
        }
        tokio::select! {
            biased;
            _=cancelled.changed()=>{},
            _=stopped.changed()=>{},
            _=async {
                if let Ok(Ok((mut socket,_)))=tokio::time::timeout(Duration::from_secs(10),listener.accept()).await {
                    drop(listener);
                    let _=std::fs::remove_file(&_guard.0);
                    let _=tokio::time::timeout(Duration::from_secs(120),tokio::io::copy_bidirectional(&mut socket,&mut tunnel)).await;
                }
            }=>{},
        }
    });
    session.bridges.lock().map_err(|_| INTERNAL)?.push(task);
    Ok(json!({"path":path.to_string_lossy()}))
}
async fn stop(value: &Value) -> Result<Value> {
    let handle = value.get("handle").and_then(Value::as_u64).ok_or(INVALID)?;
    let session = SESSIONS.lock().map_err(|_| INTERNAL)?.remove(&handle);
    if let Some(session) = session {
        session.stopped.send_replace(true);
        let tasks: Vec<_> = session
            .bridges
            .lock()
            .map_err(|_| INTERNAL)?
            .drain(..)
            .collect();
        for task in &tasks {
            task.abort();
        }
        for task in tasks {
            let _ = task.await;
        }
        let _ = tokio::time::timeout(Duration::from_secs(5), session.client.shutdown()).await;
    }
    Ok(json!({}))
}

#[cfg(test)]
mod tests;
