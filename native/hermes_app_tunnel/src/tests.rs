use super::*;
use async_trait::async_trait;
use hermes_transport::{HttpRequest, HttpResponse, HttpTransportError};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, UnixStream};
use tokio_rustls::TlsAcceptor;
const CERT: &[u8] = include_bytes!("../tests/fixtures/synthetic-cert.der");
const KEY: &[u8] = include_bytes!("../tests/fixtures/synthetic-key.der");

#[test]
fn ffi_errors_are_fixed_and_session_validation_precedes_network() {
    let input=CString::new(r#"{"op":"start","gatewayUrl":"http://example.invalid/","session":{"sid":"SYNTHETIC_PRIVATE"}}"#).unwrap();
    let output = unsafe { elecon_hermes_call(input.as_ptr()) };
    let text = unsafe { CStr::from_ptr(output) }.to_str().unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(text).unwrap(),
        json!({"ok":false,"error":CONFIG})
    );
    assert!(!text.contains("SYNTHETIC_PRIVATE"));
    unsafe { elecon_hermes_free(output) };
    assert_eq!(
        call(
            json!({"op":"dial","handle":u64::MAX,"host":"example.invalid","address":"192.0.2.7","port":443})
        ),
        Err(CLOSED)
    );
}
#[test]
fn cancel_before_worker_registration_prevents_initialization() {
    let id = random_id();
    call(json!({"op":"cancel","requestId":id})).unwrap();
    assert_eq!(call(json!({"op":"start","requestId":id})), Err(CANCELLED));
}
#[test]
fn bad_storage_scope_is_rejected_and_private_ht_is_tightened() {
    let root = std::env::temp_dir().join(format!("elecon-hermes-{}", random_id()));
    std::fs::create_dir(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let ht = root.join("ht");
    std::fs::create_dir(&ht).unwrap();
    std::fs::set_permissions(&ht, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(private_directory(ht.to_str().unwrap()).is_ok());
    assert_eq!(
        std::fs::metadata(&ht).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert!(private_directory("/tmp").is_err());
    let link = root.join("link");
    std::os::unix::fs::symlink(&ht, &link).unwrap();
    assert!(private_directory(link.to_str().unwrap()).is_err());
    std::fs::remove_dir_all(root).unwrap();
}
fn tls_config() -> Arc<rustls::ServerConfig> {
    let cert = rustls::pki_types::CertificateDer::from(CERT.to_vec());
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
        KEY.to_vec(),
    ));
    Arc::new(
        rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap(),
    )
}
#[tokio::test]
async fn certificate_pin_requires_exact_certificate_and_real_tls_signatures() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let acceptor = TlsAcceptor::from(tls_config());
    let peer = tokio::spawn(async move {
        for _ in 0..3 {
            let (socket, _) = listener.accept().await.unwrap();
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let _ = acceptor.accept(socket).await;
            });
        }
    });
    let pin: [u8; 32] = Sha256::digest(CERT).into();
    assert!(
        hermes_transport::connect_tls("127.0.0.1", port, TlsPolicy::PinnedCertificateSha256(pin))
            .await
            .is_ok()
    );
    assert!(
        hermes_transport::connect_tls(
            "127.0.0.1",
            port,
            TlsPolicy::PinnedCertificateSha256([0; 32])
        )
        .await
        .is_err()
    );
    assert!(
        hermes_transport::connect_tls("127.0.0.1", port, TlsPolicy::Verify)
            .await
            .is_err()
    );
    peer.await.unwrap();
}
struct ResourceTransport {
    port: u16,
}
#[async_trait]
impl HttpTransport for ResourceTransport {
    async fn execute(
        &self,
        _: HttpRequest,
    ) -> std::result::Result<HttpResponse, HttpTransportError> {
        Ok(HttpResponse{status:200,location:None,body:json!({"code":0,"data":{"appList":{"data":{
            "appInfo":[{"apps":[{"id":"synthetic-app","nodeGroupId":"synthetic-node","addressList":[{"protocol":"tcp","port":"443","host":"service.synthetic.invalid","ip":["192.0.2.7"]}]}]}],
            "config":{"nodeGroupConf":{"nodeGroupList":[{"id":"synthetic-node","addressInfo":[{"address":format!("127.0.0.1:{}",self.port),"addressType":"ip"}]}]}}
        }},"sdpPolicy":{"data":{}}}}).to_string().into_bytes()})
    }
}
#[tokio::test]
async fn hermes_tunnel_uses_pinned_ip_and_single_private_socket_then_stop_cleans_up() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let acceptor = TlsAcceptor::from(tls_config());
    let peer = tokio::spawn(async move {
        let (socket, _) = listener.accept().await.unwrap();
        let mut tls = acceptor.accept(socket).await.unwrap();
        let mut prefix = [0u8; 5];
        tls.read_exact(&mut prefix).await.unwrap();
        assert_eq!(prefix, [5, 1, 0x81, 0x53, 3]);
        let length = tls.read_u16().await.unwrap();
        let mut init = vec![0; length as usize];
        tls.read_exact(&mut init).await.unwrap();
        let init: Value = serde_json::from_slice(&init).unwrap();
        assert_eq!(init["destAddr"], "192.0.2.7:443");
        let mut destination = [0u8; 10];
        tls.read_exact(&mut destination).await.unwrap();
        assert_eq!(destination, [5, 1, 1, 1, 192, 0, 2, 7, 1, 187]);
        tls.write_all(&[0x53, 0, 0, 2, b'O', b'K']).await.unwrap();
        let mut probe = [0u8; 4];
        tls.read_exact(&mut probe).await.unwrap();
        assert_eq!(probe, [1, 0, 0, 0]);
        tls.write_all(&[5, 0]).await.unwrap();
        tls.flush().await.unwrap();
        let mut header = [0u8; 4];
        tls.read_exact(&mut header).await.unwrap();
        assert_eq!(&header[..2], &[1, 0]);
        let mut payload = vec![0; u16::from_be_bytes([header[2], header[3]]) as usize];
        tls.read_exact(&mut payload).await.unwrap();
        assert_eq!(payload, b"SYNTHETIC_PAYLOAD");
        tls.write_all(&header).await.unwrap();
        tls.write_all(&payload).await.unwrap();
        tls.flush().await.unwrap();
    });
    let gateway = GatewayEndpoint::new("gateway.synthetic.invalid", 443).unwrap();
    let auth = Arc::new(AuthClient::new(
        gateway.clone(),
        Arc::new(ResourceTransport { port }),
    ));
    let configuration = atrust_auth::AuthConfiguration {
        login_state: atrust_auth::LoginState::LoggedIn,
        methods: vec![],
        csrf_token: "synthetic".into(),
        public_key: String::new(),
        public_key_exponent: String::new(),
        anti_replay_random: String::new(),
    };
    let material = SessionMaterial::from_parts(
        SessionId::new("synthetic-sid").unwrap(),
        DeviceId::new("synthetic-device").unwrap(),
        ConnectionId::new("synthetic-connection").unwrap(),
        SignKey::from_hex(&"ab".repeat(32)).unwrap(),
        Some("synthetic-user".into()),
        false,
        "sid".into(),
        false,
    );
    let config = AtrustClientConfig::new(
        gateway,
        TlsPolicy::PinnedCertificateSha256(Sha256::digest(CERT).into()),
    );
    let client = AtrustClient::start(auth, configuration, material, config)
        .await
        .unwrap();
    let directory = std::env::temp_dir().join(format!("eh-{}", random_id()));
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
    let (stopped, _) = watch::channel(false);
    let session = Arc::new(Session {
        client,
        directory: directory.clone(),
        stopped,
        bridges: Mutex::new(vec![]),
        resolved: Mutex::new(HashMap::new()),
        _slot: SESSION_SLOTS.clone().try_acquire_owned().unwrap(),
    });
    let answer = resolve(&session, &json!({"host":"service.synthetic.invalid"}))
        .await
        .unwrap();
    assert_eq!(answer, json!({"addresses":["192.0.2.7"]}));
    assert_eq!(
        dial(
            &session,
            &json!({"host":"service.synthetic.invalid","address":"192.0.2.8","port":443}),
            Arc::new(Control::new())
        )
        .await,
        Err("hermes_not_authorized")
    );
    let signal = Arc::new(Control::new());
    let result = dial(
        &session,
        &json!({"host":"service.synthetic.invalid","address":"192.0.2.7","port":443}),
        signal,
    )
    .await
    .unwrap();
    let path = result["path"].as_str().unwrap();
    let mut socket = UnixStream::connect(path).await.unwrap();
    socket.write_all(b"SYNTHETIC_PAYLOAD").await.unwrap();
    let mut result = [0u8; 17];
    socket.read_exact(&mut result).await.unwrap();
    assert_eq!(&result, b"SYNTHETIC_PAYLOAD");
    assert!(UnixStream::connect(path).await.is_err());
    peer.await.unwrap();
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    SESSIONS.lock().unwrap().insert(handle, session);
    stop(&json!({"handle":handle})).await.unwrap();
    assert!(!std::path::Path::new(path).exists());
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn in_flight_initialization_is_cancelled_before_any_handle_can_escape() {
    use std::io::Read;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (accepted, ready) = std::sync::mpsc::channel();
    let peer = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        accepted.send(()).unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        let mut bytes = [0u8; 4096];
        while matches!(socket.read(&mut bytes),Ok(n) if n>0) {}
    });
    let directory = std::env::temp_dir().join(format!("eh-{}", random_id()));
    std::fs::create_dir(&directory).unwrap();
    std::fs::set_permissions(&directory, std::fs::Permissions::from_mode(0o700)).unwrap();
    let id = random_id();
    let pending = id.clone();
    let path = directory.clone();
    let worker = std::thread::spawn(move || {
        call(
            json!({"op":"start","requestId":pending,"gatewayUrl":format!("https://127.0.0.1:{port}/"),"socketDirectory":path,
        "session":{"version":1,"saved_unix_ms":0,"gateway_host":"127.0.0.1","gateway_port":port,"login_method":"cas","login_domain":null,
        "cookies":[],"sid":"synthetic-sid","sid_cookie_name":"sid","sid_sig_present":false,"device_id":"synthetic-device","connection_id":"synthetic-connection","sign_key_hex":"ab".repeat(32),"sign_key_provisional":true,"username":"synthetic-user"}}),
        )
    });
    ready.recv_timeout(Duration::from_secs(3)).unwrap();
    call(json!({"op":"cancel","requestId":id})).unwrap();
    assert_eq!(worker.join().unwrap(), Err(CANCELLED));
    peer.join().unwrap();
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn gateway_cookie_import_tightens_parent_domain_and_secure_attribute() {
    let endpoint = GatewayEndpoint::new("vpn.synthetic.invalid", 443).unwrap();
    let cookies = vec![Cookie {
        name: "sid".into(),
        value: "synthetic-private-sid".into(),
        domain: Some(".synthetic.invalid".into()),
        path: Some("/".into()),
        secure: false,
        http_only: true,
    }];
    let transport = transport(&endpoint, &cookies).unwrap();
    let origin = url::Url::parse("https://vpn.synthetic.invalid/").unwrap();
    let exported = transport.session_cookies(&origin);
    assert_eq!(exported.len(), 1);
    assert_eq!(exported[0].domain.as_deref(), Some("vpn.synthetic.invalid"));
    assert!(exported[0].secure);
    assert!(
        transport
            .session_cookies(&url::Url::parse("https://other.synthetic.invalid/").unwrap())
            .is_empty()
    );
}
