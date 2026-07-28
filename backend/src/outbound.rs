//! Shared policy for user-configured outbound HTTP services.
//!
//! LLM and ntfy endpoints are useful precisely because they can be
//! self-hosted, but an arbitrary authenticated account must not turn the
//! server into a proxy for loopback, cloud metadata, or other private hosts.
//! This module centralizes URL validation, DNS resolution, and resolver
//! pinning so every user-controlled integration follows the same rule.

use std::collections::HashSet;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use anyhow::{Context, bail};
use futures::StreamExt;

pub(crate) struct ResolvedHttpUrl {
    pub url: reqwest::Url,
    host: String,
    addrs: Vec<SocketAddr>,
}

impl ResolvedHttpUrl {
    /// Build a client pinned to the addresses that were security-checked.
    /// Redirects stay disabled because a public endpoint could otherwise
    /// redirect a validated request into the private network.
    pub fn client_builder(&self) -> reqwest::ClientBuilder {
        reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .resolve_to_addrs(&self.host, &self.addrs)
    }
}

pub(crate) fn allow_private_user_endpoints() -> bool {
    matches!(
        std::env::var("STICKY_NOTES_ALLOW_PRIVATE_USER_ENDPOINTS")
            .ok()
            .as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

pub(crate) async fn resolve_http_url(
    raw: &str,
    allow_private: bool,
) -> anyhow::Result<ResolvedHttpUrl> {
    let url = reqwest::Url::parse(raw.trim()).context("endpoint is not a valid URL")?;
    if !matches!(url.scheme(), "http" | "https") {
        bail!("endpoint must use http or https");
    }
    if !url.username().is_empty() || url.password().is_some() {
        bail!("endpoint must not contain URL credentials");
    }
    let host = url
        .host_str()
        .filter(|host| !host.is_empty())
        .context("endpoint has no host")?
        .to_ascii_lowercase();
    if !allow_private && (host == "localhost" || host.ends_with(".localhost")) {
        bail!("private service endpoints are disabled by the server");
    }
    let port = url
        .port_or_known_default()
        .context("endpoint has no usable port")?;
    let mut seen = HashSet::new();
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .with_context(|| format!("could not resolve endpoint host {host}"))?
        .filter(|addr| seen.insert(*addr))
        .collect();
    if addrs.is_empty() {
        bail!("endpoint host did not resolve");
    }
    if !allow_private && addrs.iter().any(|addr| ip_is_blocked(addr.ip())) {
        bail!("private service endpoints are disabled by the server");
    }
    Ok(ResolvedHttpUrl { url, host, addrs })
}

/// Read a response only up to `limit`; success payloads over the contract cap
/// are rejected instead of being buffered without bound.
pub(crate) async fn read_body_capped(
    response: reqwest::Response,
    limit: usize,
) -> anyhow::Result<Vec<u8>> {
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        if body.len().saturating_add(chunk.len()) > limit {
            bail!("upstream response exceeded {} bytes", limit);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Read an error-body prefix without waiting for or retaining an arbitrarily
/// large provider response.
pub(crate) async fn read_body_prefix(response: reqwest::Response, limit: usize) -> Vec<u8> {
    let mut stream = response.bytes_stream();
    let mut body = Vec::new();
    while body.len() < limit {
        let Some(chunk) = stream.next().await else {
            break;
        };
        let Ok(chunk) = chunk else {
            break;
        };
        let remaining = limit - body.len();
        body.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
    }
    body
}

/// Non-routable / internal address ranges refused by outbound URL guards.
/// `IpAddr::is_global` is unstable, so the ranges are checked explicitly.
pub(crate) fn ip_is_blocked(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_documentation()
                || v4.is_unspecified()
                || o[0] == 0
                || (o[0] == 100 && (64..=127).contains(&o[1]))
                || o[0] >= 224
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return ip_is_blocked(IpAddr::V4(v4));
            }
            let seg = v6.segments();
            v6.is_loopback()
                || v6.is_unspecified()
                || (seg[0] & 0xfe00) == 0xfc00
                || (seg[0] & 0xffc0) == 0xfe80
                || (seg[0] & 0xff00) == 0xff00
        }
    }
}

pub(crate) const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn private_targets_require_an_explicit_opt_in() {
        assert!(
            resolve_http_url("http://127.0.0.1:8080/v1", false)
                .await
                .is_err()
        );
        let allowed = resolve_http_url("http://127.0.0.1:8080/v1", true)
            .await
            .unwrap();
        assert_eq!(allowed.url.as_str(), "http://127.0.0.1:8080/v1");
    }

    #[tokio::test]
    async fn rejects_non_http_and_embedded_credentials() {
        assert!(resolve_http_url("file:///etc/passwd", true).await.is_err());
        assert!(
            resolve_http_url("https://user:secret@example.com/v1", true)
                .await
                .is_err()
        );
    }
}
