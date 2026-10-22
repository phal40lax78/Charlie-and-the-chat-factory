//! The ntfy poll's one HTTPS GET (SPEC 7 "M3: Native listening"), as
//! [Get-ChatqReplyFeed](src/phone.ps1) makes it: no Authorization header,
//! the body read whole and decoded once, never a throw. A fresh agent per
//! poll burst, dropped after it, so nothing of TLS stays between polls.

use std::sync::Mutex;
use std::time::{Duration, Instant};
use ureq::Agent;
use ureq::tls::{RootCerts, TlsConfig, TlsProvider};

/// One deadline for the whole call, connect to last body byte: PowerShell's
/// `-TimeoutSec 8`.
pub const TIMEOUT: Duration = Duration::from_secs(8);
/// Windows PowerShell 5.1's `MaximumRedirection` default; ureq's own is 10.
const MAX_REDIRECTS: u32 = 5;
/// ureq's own `read_to_vec` limit, kept and named: 10 MiB is about 25,000
/// ntfy lines, far past any poll's `since` window.
const BODY_LIMIT: u64 = 10 * 1024 * 1024;

/// Why a fetch failed, as a fixed text: ureq's own messages may carry the
/// URL, and so the topic, which no log line may hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fail {
    Timeout,
    HostNotFound,
    Connect,
    /// the system refused this exe the connect itself (WSAEACCES, 10013):
    /// a firewall blocking programs by default, which lets PowerShell out
    Forbidden,
    Tls,
    Proxy,
    ProxyAuth,
    Status(u16),
    TooBig,
    Redirects,
    BadUrl,
    Other,
}

impl Fail {
    pub fn text(self) -> String {
        match self {
            Fail::Timeout => "the request timed out".into(),
            Fail::HostNotFound => "the server's name did not resolve".into(),
            Fail::Connect => "the connection failed".into(),
            Fail::Forbidden if cfg!(windows) => {
                "Windows does not let chatqd connect (a firewall?)".into()
            }
            Fail::Forbidden => "the system does not let chatqd connect (a firewall?)".into(),
            Fail::Tls => "the TLS handshake failed".into(),
            Fail::Proxy => "the proxy refused the connection".into(),
            Fail::ProxyAuth => "proxy needs authentication".into(),
            Fail::Status(code) => format!("the server answered {code}"),
            Fail::TooBig => "the answer was too long".into(),
            Fail::Redirects => "too many redirects".into(),
            Fail::BadUrl => "the address is not usable".into(),
            Fail::Other => "the request failed".into(),
        }
    }

    fn of(e: &ureq::Error) -> Fail {
        use ureq::Error as E;
        match e {
            E::Timeout(_) => Fail::Timeout,
            E::HostNotFound => Fail::HostNotFound,
            // std reads WSAEACCES (and EACCES/EPERM) as PermissionDenied
            E::Io(io) if io.kind() == std::io::ErrorKind::PermissionDenied => Fail::Forbidden,
            E::ConnectionFailed | E::Io(_) => Fail::Connect,
            E::Tls(_) | E::NativeTls(_) | E::Der(_) | E::Pem(_) => Fail::Tls,
            E::ConnectProxyFailed(why) if why.starts_with("proxy server responded 407") => {
                Fail::ProxyAuth
            }
            E::ConnectProxyFailed(_) | E::InvalidProxyUrl => Fail::Proxy,
            E::StatusCode(code) => Fail::Status(*code),
            E::BodyExceedsLimit(_) | E::LargeResponseHeader(..) => Fail::TooBig,
            E::TooManyRedirects | E::RedirectFailed => Fail::Redirects,
            E::BadUri(_) | E::Http(_) => Fail::BadUrl,
            _ => Fail::Other,
        }
    }
}

/// The agent for one burst: native TLS (SChannel) with the system's roots,
/// set by hand since ureq's defaults are rustls and WebPki roots; no
/// environment proxy, only `proxy`, the one resolved from the system.
pub(crate) fn agent(proxy: Option<&str>) -> Result<Agent, Fail> {
    let proxy = match proxy {
        Some(p) => Some(ureq::Proxy::new(p).map_err(|_| Fail::Proxy)?),
        None => None,
    };
    let tls = TlsConfig::builder()
        .provider(TlsProvider::NativeTls)
        .root_certs(RootCerts::PlatformVerifier)
        .build();
    Ok(Agent::config_builder()
        .tls_config(tls)
        .proxy(proxy)
        .timeout_global(Some(TIMEOUT))
        .max_redirects(MAX_REDIRECTS)
        .build()
        .into())
}

/// One GET of `url` through `proxy` (None: direct), the body decoded as
/// UTF-8 with bad bytes replaced, as .NET's `UTF8Encoding.GetString` does.
pub fn fetch(url: &str, proxy: Option<&str>) -> Result<String, Fail> {
    let agent = agent(proxy)?;
    let mut resp = agent.get(url).call().map_err(|e| Fail::of(&e))?;
    let bytes = resp
        .body_mut()
        .with_config()
        .limit(BODY_LIMIT)
        .read_to_vec()
        .map_err(|e| Fail::of(&e))?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// The `connectForbidden` seam's [get]: the connect refused as a firewall
/// refuses it (WSAEACCES on Windows, EACCES elsewhere), read by the same
/// mapping; nothing is sent anywhere.
pub fn get_forbidden(_url: &str) -> Result<String, Fail> {
    let code = if cfg!(windows) { 10013 } else { 13 };
    let e = std::io::Error::from_raw_os_error(code);
    Err(Fail::of(&ureq::Error::Io(e)))
}

/// The system proxy for an origin, cached: resolving it can mean WPAD,
/// seconds long. Resolved again after [PROXY_FOR], so a network change is
/// picked up, and at once after a failure that names the route.
static PROXY: Mutex<Option<Route>> = Mutex::new(None);
/// How long a resolved proxy is kept.
const PROXY_FOR: Duration = Duration::from_secs(5 * 60);

struct Route {
    origin: String,
    proxy: Option<String>,
    at: Instant,
}

/// The host of `scheme://[user@]host[:port]/…`.
pub(crate) fn url_host(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, r)| r);
    let auth = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    let auth = auth.rsplit_once('@').map_or(auth, |(_, h)| h);
    if let Some(v6) = auth.strip_prefix('[') {
        return v6.split(']').next().unwrap_or(v6);
    }
    auth.split(':').next().unwrap_or(auth)
}

/// `Uri.IsLoopback`: `localhost`, 127.0.0.0/8 or `::1`.
pub(crate) fn loopback(host: &str) -> bool {
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback())
}

/// `scheme://authority/` of `url`: all the proxy lookup sees, so neither
/// the topic nor `since` reaches a PAC script.
fn origin(url: &str) -> String {
    let (scheme, rest) = url.split_once("://").unwrap_or(("", url));
    let auth = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    format!("{scheme}://{auth}/")
}

/// Does `fail` through `proxy` say the route is wrong? A proxy refusing,
/// asking for credentials, or not answering; a server's own answer says
/// nothing about the route to it.
fn route_failed(fail: Fail, proxy: bool) -> bool {
    match fail {
        Fail::Proxy | Fail::ProxyAuth => true,
        Fail::Connect | Fail::HostNotFound | Fail::Timeout => proxy,
        _ => false,
    }
}

/// [fetch] through the system's proxy for `url`. ureq tunnels plain http
/// through CONNECT as well, so a proxy's 407 is a CONNECT failure; a 407
/// answered through a proxy all the same is [Fail::ProxyAuth] too.
pub fn get(url: &str) -> Result<String, Fail> {
    let key = origin(url);
    let now = Instant::now();
    let proxy = {
        let mut cache = PROXY.lock().unwrap_or_else(|e| e.into_inner());
        match &*cache {
            Some(r) if r.origin == key && now.duration_since(r.at) < PROXY_FOR => r.proxy.clone(),
            _ => {
                let proxy = crate::sys::system_proxy(&key);
                *cache = Some(Route {
                    origin: key,
                    proxy: proxy.clone(),
                    at: now,
                });
                proxy
            }
        }
    };
    let r = match fetch(url, proxy.as_deref()) {
        Err(Fail::Status(407)) if proxy.is_some() => Err(Fail::ProxyAuth),
        r => r,
    };
    if matches!(r, Err(f) if route_failed(f, proxy.is_some())) {
        *PROXY.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_loopback_host_is_never_proxied() {
        for h in ["localhost", "LocalHost", "127.0.0.1", "127.9.8.7", "::1"] {
            assert!(loopback(h), "{h}");
        }
        for h in ["ntfy.sh", "128.0.0.1", "::2", "localhost.example"] {
            assert!(!loopback(h), "{h}");
        }
        assert_eq!(url_host("http://[::1]:8080/"), "::1");
        assert_eq!(url_host("https://u@ntfy.sh:443/t/json?x"), "ntfy.sh");
        assert_eq!(
            origin("https://ntfy.sh/topic/json?poll=1"),
            "https://ntfy.sh/"
        );
    }

    /// A loopback server giving every connection `answer` once its request
    /// head is in (a close with bytes unread is a reset on Windows), or at
    /// once for a TLS hello, which has no head to wait for.
    fn serve(answer: &'static [u8]) -> String {
        use std::io::{Read, Write};
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let at = l.local_addr().unwrap().to_string();
        std::thread::spawn(move || {
            for mut c in l.incoming().flatten() {
                let (mut head, mut b) = (Vec::new(), [0u8; 1]);
                while !head.ends_with(b"\r\n\r\n")
                    && head.first() != Some(&0x16)
                    && c.read(&mut b).is_ok_and(|n| n == 1)
                {
                    head.push(b[0]);
                }
                let _ = c.write_all(answer);
            }
        });
        at
    }

    #[test]
    fn a_proxy_asking_for_credentials_is_proxy_auth() {
        let proxy = serve(
            b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: NTLM\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
        let proxy = format!("http://{proxy}");
        // ureq tunnels a plain-http poll through CONNECT too
        for url in [
            "https://ntfy.invalid/topic/json?poll=1",
            "http://ntfy.invalid/topic/json?poll=1",
        ] {
            assert_eq!(fetch(url, Some(&proxy)), Err(Fail::ProxyAuth), "{url}");
        }
        assert!(route_failed(Fail::ProxyAuth, true));
    }

    #[test]
    fn a_connect_the_system_refuses_is_forbidden() {
        assert_eq!(get_forbidden("http://127.0.0.1:9/t"), Err(Fail::Forbidden));
        let refused = std::io::Error::from(std::io::ErrorKind::ConnectionRefused);
        assert_eq!(Fail::of(&ureq::Error::Io(refused)), Fail::Connect);
        assert!(!route_failed(Fail::Forbidden, true), "no proxy is to blame");
        assert!(!Fail::Forbidden.text().contains("http"));
    }

    #[test]
    fn tls_against_a_plain_server_fails_as_tls() {
        let at = serve(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n");
        let r = fetch(&format!("https://{at}/topic/json"), None);
        assert!(matches!(r, Err(Fail::Tls | Fail::Connect)), "{r:?}");
    }
}
