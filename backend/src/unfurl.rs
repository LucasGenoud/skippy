//! Link "unfurling": fetch a URL server-side and extract Open Graph / HTML
//! metadata (title, description, image, site name, favicon) so the client can
//! render a rich preview card. The Flutter web app can't fetch arbitrary
//! cross-origin pages itself, hence the server does it.
//!
//! Minimal-dependency style (no `url`/`scraper`/`regex` crates): URLs are
//! hand-parsed and the HTML is scanned with a small tolerant tag reader, the
//! same hand-rolled approach used for SigV4 in `files.rs` and SSE in `llm.rs`.
//!
//! Because the server fetches user-supplied URLs, `validate_public_http_url`
//! is an SSRF guard: it rejects loopback/private/link-local addresses (and
//! resolves DNS so a public hostname can't point at an internal IP). The env
//! `STICKY_NOTES_UNFURL_ALLOW_PRIVATE=1` disables it (self-hosters unfurling
//! internal links; also used by the e2e/localhost tests).

use std::collections::HashSet;
use std::net::SocketAddr;
use std::time::Duration;

use anyhow::{Context, anyhow, bail};
use futures::StreamExt;
use reqwest::header::{ACCEPT, CONTENT_TYPE, LOCATION, USER_AGENT};
use serde::Serialize;

/// Metadata extracted from a page, mirrored by the Flutter `LinkPreview` model.
/// Every field except `url` is optional, a bare link still yields a card with
/// the host as its title.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LinkPreview {
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub image: Option<String>,
    pub site_name: Option<String>,
    pub favicon: Option<String>,
}

impl LinkPreview {
    /// A minimal preview built only from the URL itself, used when the page
    /// can't be fetched or parsed, so the client always has something to show.
    fn host_only(parsed: &ParsedUrl) -> Self {
        LinkPreview {
            url: parsed.full.clone(),
            title: None,
            description: None,
            image: None,
            site_name: Some(parsed.host.clone()),
            favicon: Some(parsed.resolve("/favicon.ico")),
        }
    }
}

// Hard cap on how much of a body we'll pull. Metadata lives in `<head>`, and
// big sites (YouTube, etc.) inline hundreds of KB of script/JSON *before* their
// Open Graph tags, so this has to be generous, `read_capped` stops early once
// `</head>` arrives, so the full cap is only ever hit on pages with no head end.
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
const MAX_REDIRECTS: usize = 6;

fn client(target: &ParsedUrl) -> anyhow::Result<reqwest::Client> {
    // Resolve once during validation and pin that exact answer into reqwest.
    // Without this, a rebinding DNS server could return a public address to
    // the guard and a private one when the HTTP client resolves again.
    Ok(reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(10))
        .redirect(reqwest::redirect::Policy::none())
        .resolve_to_addrs(&target.host, &target.addrs)
        .build()?)
}

/// Whether the SSRF guard is disabled by env. Read per-call so tests can set it.
pub fn allow_private() -> bool {
    matches!(
        std::env::var("STICKY_NOTES_UNFURL_ALLOW_PRIVATE")
            .ok()
            .as_deref(),
        Some("1") | Some("true") | Some("yes") | Some("on")
    )
}

/// Fetch and parse a preview for `raw`. Returns `Err` only when the URL is
/// invalid or blocked by the SSRF guard (→ the handler answers 400); a network
/// or parse failure after a valid URL yields a host-only preview instead, so
/// the client still gets a usable card.
pub async fn preview_for(raw: &str, allow_private: bool) -> anyhow::Result<LinkPreview> {
    let parsed = validate_public_http_url(raw, allow_private).await?;
    let mut preview = match fetch_html(&parsed, allow_private).await {
        Ok((final_url, html)) => {
            let base = validate_public_http_url(&final_url, true)
                .await
                .unwrap_or(parsed);
            parse_preview(&html, &base)
        }
        Err(_) => LinkPreview::host_only(&parsed),
    };
    // Inline the favicon as a `data:` URI. Flutter web (CanvasKit) can't render
    // a cross-origin favicon fetched by `Image.network`, favicon servers don't
    // send CORS headers, so the browser taints the fetch and the client falls
    // back to a generic globe. A same-origin data URI renders identically on web
    // and mobile. On any failure we keep the original absolute URL (mobile fetch
    // is unrestricted), so this never regresses the existing behaviour.
    if let Some(fav) = preview.favicon.take() {
        preview.favicon = Some(inline_favicon(&fav, allow_private).await.unwrap_or(fav));
    }
    Ok(preview)
}

/// Favicons are tiny; anything larger than this isn't a favicon and isn't worth
/// inlining into the (cached, JSON) preview.
const MAX_FAVICON_BYTES: usize = 256 * 1024;

/// Fetch `url` and return it as a `data:` URI when it's a raster image Flutter
/// can decode everywhere. Returns `None` on any failure or for formats Flutter
/// can't decode (`.ico`, SVG) so the caller falls back to the absolute URL.
async fn inline_favicon(url: &str, allow_private: bool) -> Option<String> {
    if url.starts_with("data:") {
        return Some(url.to_string());
    }
    let parsed = validate_public_http_url(url, allow_private).await.ok()?;
    let (content_type, bytes) = fetch_bytes(&parsed, allow_private, MAX_FAVICON_BYTES)
        .await
        .ok()?;
    if bytes.is_empty() {
        return None;
    }
    let mime = decodable_image_mime(&content_type, &bytes)?;
    Some(format!("data:{mime};base64,{}", base64_encode(&bytes)))
}

/// Map a response `content-type` (falling back to magic-byte sniffing) to a MIME
/// type Flutter decodes on every platform, or `None` for formats it can't
/// (`.ico`, SVG), those keep the generic globe as they always have.
fn decodable_image_mime(content_type: &str, bytes: &[u8]) -> Option<&'static str> {
    let ct = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_ascii_lowercase();
    match ct.as_str() {
        "image/png" => return Some("image/png"),
        "image/jpeg" | "image/jpg" => return Some("image/jpeg"),
        "image/gif" => return Some("image/gif"),
        "image/webp" => return Some("image/webp"),
        "image/bmp" => return Some("image/bmp"),
        // .ico and SVG (and anything else) fall through to sniffing.
        _ => {}
    }
    sniff_image_mime(bytes)
}

/// Best-effort content sniff for the raster formats Flutter can decode. Servers
/// frequently mislabel favicons (`text/plain`, `application/octet-stream`), so a
/// wrong or missing `content-type` shouldn't cost us a good PNG.
fn sniff_image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]) {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.starts_with(b"BM") {
        Some("image/bmp")
    } else {
        None
    }
}

/// Standard base64 (RFC 4648, with padding). Hand-rolled to keep the crate's
/// no-extra-deps style (see the module header).
fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = chunk.get(1).copied().unwrap_or(0) as usize;
        let b2 = chunk.get(2).copied().unwrap_or(0) as usize;
        out.push(ALPHABET[b0 >> 2] as char);
        out.push(ALPHABET[((b0 & 0x03) << 4) | (b1 >> 4)] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[((b1 & 0x0F) << 2) | (b2 >> 6)] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[b2 & 0x3F] as char
        } else {
            '='
        });
    }
    out
}

// ---------------------------------------------------------------------------
// Fetching

async fn fetch_html(start: &ParsedUrl, allow_private: bool) -> anyhow::Result<(String, String)> {
    let mut current = start.clone();
    for _ in 0..MAX_REDIRECTS {
        let resp = client(&current)?
            .get(&current.full)
            .header(ACCEPT, "text/html,application/xhtml+xml")
            .header(
                USER_AGENT,
                "Mozilla/5.0 (compatible; StickyNotesBot/1.0; +https://sticky-notes.local)",
            )
            .send()
            .await
            .context("request failed")?;
        let status = resp.status();
        if status.is_redirection() {
            let loc = resp
                .headers()
                .get(LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| anyhow!("redirect without Location"))?;
            let next = current.resolve(loc);
            current = validate_public_http_url(&next, allow_private).await?;
            continue;
        }
        if !status.is_success() {
            bail!("upstream status {status}");
        }
        // Skip non-HTML bodies (images, PDFs, JSON), there's nothing to parse.
        if let Some(ct) = resp
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
        {
            let ct = ct.to_ascii_lowercase();
            if !ct.is_empty() && !ct.contains("html") && !ct.contains("xml") {
                bail!("non-html content-type: {ct}");
            }
        }
        let bytes = read_capped(resp, MAX_BODY_BYTES).await?;
        let html = String::from_utf8_lossy(&bytes).into_owned();
        return Ok((current.full, html));
    }
    bail!("too many redirects")
}

/// Fetch a non-HTML resource (a favicon), following redirects and re-validating
/// each hop through the SSRF guard. Returns `(content_type, bytes)` with the
/// body capped at `cap`. Unlike [`fetch_html`] this doesn't stop at `</head>`.
async fn fetch_bytes(
    start: &ParsedUrl,
    allow_private: bool,
    cap: usize,
) -> anyhow::Result<(String, Vec<u8>)> {
    let mut current = start.clone();
    for _ in 0..MAX_REDIRECTS {
        let resp = client(&current)?
            .get(&current.full)
            .header(ACCEPT, "image/*")
            .header(
                USER_AGENT,
                "Mozilla/5.0 (compatible; StickyNotesBot/1.0; +https://sticky-notes.local)",
            )
            .send()
            .await
            .context("request failed")?;
        let status = resp.status();
        if status.is_redirection() {
            let loc = resp
                .headers()
                .get(LOCATION)
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| anyhow!("redirect without Location"))?;
            let next = current.resolve(loc);
            current = validate_public_http_url(&next, allow_private).await?;
            continue;
        }
        if !status.is_success() {
            bail!("upstream status {status}");
        }
        let content_type = resp
            .headers()
            .get(CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_string();
        let mut stream = resp.bytes_stream();
        let mut buf = Vec::new();
        while let Some(chunk) = stream.next().await {
            buf.extend_from_slice(&chunk.context("read body")?);
            if buf.len() >= cap {
                // Larger than any real favicon, treat as unusable and bail so
                // the caller keeps the plain URL rather than inlining a huge blob.
                bail!("favicon exceeds size cap");
            }
        }
        return Ok((content_type, buf));
    }
    bail!("too many redirects")
}

/// Read the body, stopping at whichever comes first: the end of `<head>` (all
/// the metadata we parse lives there, so there's no point downloading the rest
/// of a multi-MB page) or `cap` bytes.
async fn read_capped(resp: reqwest::Response, cap: usize) -> anyhow::Result<Vec<u8>> {
    const HEAD_CLOSE: &[u8] = b"</head>";
    let mut stream = resp.bytes_stream();
    let mut buf = Vec::new();
    let mut scanned: usize = 0; // bytes already searched for </head>
    while let Some(chunk) = stream.next().await {
        buf.extend_from_slice(&chunk.context("read body")?);
        // Search the newly-arrived bytes, backing up by len-1 so a `</head>`
        // straddling a chunk boundary is still matched.
        let from = scanned.saturating_sub(HEAD_CLOSE.len() - 1);
        if let Some(rel) = find_ci(&buf[from..], HEAD_CLOSE) {
            buf.truncate(from + rel + HEAD_CLOSE.len());
            break;
        }
        scanned = buf.len();
        if buf.len() >= cap {
            buf.truncate(cap);
            break;
        }
    }
    Ok(buf)
}

/// First index of ASCII-case-insensitive `needle` (which must be lowercase) in
/// `hay`, or `None`.
fn find_ci(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || hay.len() < needle.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| {
        w.iter()
            .zip(needle)
            .all(|(a, b)| a.to_ascii_lowercase() == *b)
    })
}

// ---------------------------------------------------------------------------
// HTML metadata parsing (pure)

/// Extract preview metadata from an HTML document. Prefers Open Graph, falls
/// back to Twitter card tags, then the `<title>` / host. Relative image and
/// favicon URLs are resolved against `base`.
pub fn parse_preview(html: &str, base: &ParsedUrl) -> LinkPreview {
    let lower = html.to_ascii_lowercase();

    let mut og_title = None;
    let mut og_desc = None;
    let mut og_image = None;
    let mut og_site = None;
    let mut tw_title = None;
    let mut tw_desc = None;
    let mut tw_image = None;
    let mut meta_desc = None;

    for tag in each_tag(html, &lower, "meta") {
        let key = get_attr(tag, "property").or_else(|| get_attr(tag, "name"));
        let Some(key) = key else { continue };
        let Some(content) = get_attr(tag, "content") else {
            continue;
        };
        let content = decode_entities(content.trim());
        if content.is_empty() {
            continue;
        }
        match key.to_ascii_lowercase().as_str() {
            "og:title" => og_title = Some(content),
            "og:description" => og_desc = Some(content),
            "og:image" | "og:image:url" | "og:image:secure_url" => {
                og_image.get_or_insert(content);
            }
            "og:site_name" => og_site = Some(content),
            "twitter:title" => tw_title = Some(content),
            "twitter:description" => tw_desc = Some(content),
            "twitter:image" | "twitter:image:src" => {
                tw_image.get_or_insert(content);
            }
            "description" => meta_desc = Some(content),
            _ => {}
        }
    }

    // Favicon: first <link rel="...icon...">, else default /favicon.ico.
    let mut favicon = None;
    for tag in each_tag(html, &lower, "link") {
        let rel = get_attr(tag, "rel")
            .unwrap_or_default()
            .to_ascii_lowercase();
        if rel.contains("icon")
            && let Some(href) = get_attr(tag, "href")
        {
            favicon = Some(decode_entities(href.trim()));
            break;
        }
    }

    let title = og_title
        .or(tw_title)
        .or_else(|| extract_title(html, &lower));
    let image = og_image.or(tw_image).map(|i| base.resolve(&i));
    let favicon = favicon
        .map(|f| base.resolve(&f))
        .or_else(|| Some(base.resolve("/favicon.ico")));

    LinkPreview {
        url: base.full.clone(),
        title,
        description: og_desc.or(tw_desc).or(meta_desc),
        image,
        site_name: og_site.or_else(|| Some(base.host.clone())),
        favicon,
    }
}

fn extract_title(html: &str, lower: &str) -> Option<String> {
    let start = lower.find("<title")?;
    let gt = lower[start..].find('>')? + start + 1;
    let end = lower[gt..].find("</title>")? + gt;
    let title = decode_entities(html[gt..end].trim());
    (!title.is_empty()).then_some(title)
}

/// All `<tagname ...>` opening tags (their raw text incl. angle brackets).
fn each_tag<'a>(html: &'a str, lower: &str, tagname: &str) -> Vec<&'a str> {
    let needle = format!("<{tagname}");
    let mut out = Vec::new();
    let mut i = 0;
    while let Some(p) = lower[i..].find(&needle) {
        let start = i + p;
        let after = start + needle.len();
        // Guard against `<metaphor>` etc.: the char after the name must end it.
        let boundary = html
            .as_bytes()
            .get(after)
            .is_none_or(|b| b.is_ascii_whitespace() || *b == b'>' || *b == b'/');
        let end = lower[start..]
            .find('>')
            .map(|e| start + e + 1)
            .unwrap_or(html.len());
        if boundary {
            out.push(&html[start..end]);
        }
        i = end.max(start + 1);
    }
    out
}

/// First value of attribute `name` within a single tag's text. Handles
/// single/double-quoted and bare values.
fn get_attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    let bytes = tag.as_bytes();
    let mut search = 0;
    while let Some(p) = lower[search..].find(name) {
        let idx = search + p;
        let after = idx + name.len();
        let before_ok = idx == 0 || bytes[idx - 1].is_ascii_whitespace();
        // Skip optional whitespace between the name and '='.
        let mut j = after;
        while j < bytes.len() && bytes[j].is_ascii_whitespace() {
            j += 1;
        }
        if before_ok && bytes.get(j) == Some(&b'=') {
            let mut k = j + 1;
            while k < bytes.len() && bytes[k].is_ascii_whitespace() {
                k += 1;
            }
            if k >= bytes.len() {
                return None;
            }
            let q = bytes[k];
            if q == b'"' || q == b'\'' {
                let rest = &tag[k + 1..];
                let end = rest.find(q as char)?;
                return Some(rest[..end].to_string());
            }
            let rest = &tag[k..];
            let end = rest
                .find(|c: char| c.is_whitespace() || c == '>')
                .unwrap_or(rest.len());
            return Some(rest[..end].trim_end_matches('/').to_string());
        }
        search = after;
    }
    None
}

/// Decode the handful of HTML entities that actually show up in titles.
fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    s.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&#x2F;", "/")
        .replace("&#47;", "/")
        .replace("&nbsp;", " ")
        .replace("&apos;", "'")
}

// ---------------------------------------------------------------------------
// URL parsing + SSRF guard

/// A minimally-parsed absolute http(s) URL.
#[derive(Debug, Clone)]
pub struct ParsedUrl {
    pub scheme: String,
    pub host: String,
    pub port: u16,
    /// Absolute request path (leading `/`, may include query/fragment).
    pub path: String,
    /// Reassembled `scheme://authority/path` used for requests.
    pub full: String,
    /// DNS result checked by the SSRF policy and pinned into reqwest.
    addrs: Vec<SocketAddr>,
}

impl ParsedUrl {
    fn authority(&self) -> String {
        let default = if self.scheme == "https" { 443 } else { 80 };
        let host = if self.host.contains(':') {
            format!("[{}]", self.host)
        } else {
            self.host.clone()
        };
        if self.port == default {
            host
        } else {
            format!("{host}:{}", self.port)
        }
    }

    /// Resolve a possibly-relative reference against this URL.
    pub fn resolve(&self, href: &str) -> String {
        let href = href.trim();
        if href.starts_with("http://") || href.starts_with("https://") {
            return href.to_string();
        }
        if let Some(rest) = href.strip_prefix("//") {
            return format!("{}://{}", self.scheme, rest);
        }
        if href.starts_with('/') {
            return format!("{}://{}{}", self.scheme, self.authority(), href);
        }
        // Relative to the current path's directory.
        let dir = match self.path.rfind('/') {
            Some(i) => &self.path[..=i],
            None => "/",
        };
        format!("{}://{}{}{}", self.scheme, self.authority(), dir, href)
    }
}

/// Parse `raw` as an absolute http(s) URL and, unless `allow_private`, reject
/// it when the host resolves to any loopback/private/link-local address.
pub async fn validate_public_http_url(raw: &str, allow_private: bool) -> anyhow::Result<ParsedUrl> {
    let raw = raw.trim();
    let (scheme, rest) = raw
        .split_once("://")
        .ok_or_else(|| anyhow!("url must be absolute http(s)"))?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        bail!("only http and https URLs are allowed");
    }
    // authority = up to the first '/', '?' or '#'.
    let auth_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..auth_end];
    let path = &rest[auth_end..];
    // Strip any userinfo.
    let hostport = authority
        .rsplit_once('@')
        .map(|(_, h)| h)
        .unwrap_or(authority);
    if hostport.is_empty() {
        bail!("url has no host");
    }
    // Split host / port, honoring [ipv6] literals.
    let (host, port) = if let Some(rest) = hostport.strip_prefix('[') {
        let end = rest.find(']').ok_or_else(|| anyhow!("bad ipv6 literal"))?;
        let host = &rest[..end];
        let port = rest[end + 1..]
            .strip_prefix(':')
            .and_then(|p| p.parse().ok());
        (host.to_string(), port)
    } else if let Some((h, p)) = hostport.rsplit_once(':') {
        // Only treat the tail as a port if it's numeric (avoids eating IPv6).
        match p.parse::<u16>() {
            Ok(port) => (h.to_string(), Some(port)),
            Err(_) => (hostport.to_string(), None),
        }
    } else {
        (hostport.to_string(), None)
    };
    let host = host.to_ascii_lowercase();
    if host.is_empty() {
        bail!("url has no host");
    }
    let port = port.unwrap_or(if scheme == "https" { 443 } else { 80 });

    if !allow_private && (host == "localhost" || host.ends_with(".localhost")) {
        bail!("refusing to fetch a loopback host");
    }
    // Resolve even when private targets are allowed: the same answer is pinned
    // into the HTTP client, closing the DNS-rebinding gap in both modes.
    let mut seen = HashSet::new();
    let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
        .await
        .with_context(|| format!("could not resolve {host}"))?
        .filter(|addr| seen.insert(*addr))
        .collect();
    if addrs.is_empty() {
        bail!("host did not resolve");
    }
    if !allow_private
        && addrs
            .iter()
            .any(|addr| crate::outbound::ip_is_blocked(addr.ip()))
    {
        bail!("refusing to fetch a private/loopback address");
    }

    let display_host = if host.contains(':') {
        format!("[{host}]")
    } else {
        host.clone()
    };
    let full = format!(
        "{scheme}://{}{}",
        if port == if scheme == "https" { 443 } else { 80 } {
            display_host
        } else {
            format!("{display_host}:{port}")
        },
        if path.is_empty() { "/" } else { path }
    );
    Ok(ParsedUrl {
        scheme,
        host,
        port,
        path: if path.is_empty() {
            "/".to_string()
        } else {
            path.to_string()
        },
        full,
        addrs,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> ParsedUrl {
        // URL-resolution and metadata parsing are pure; keep these tests
        // independent from Tokio and DNS.
        ParsedUrl {
            scheme: "https".to_string(),
            host: "example.com".to_string(),
            port: 443,
            path: "/a/b".to_string(),
            full: "https://example.com/a/b".to_string(),
            addrs: Vec::new(),
        }
    }

    #[test]
    fn parses_open_graph_tags() {
        let html = r#"
            <html><head>
            <title>Fallback</title>
            <meta property="og:title" content="Rick &amp; Morty">
            <meta property="og:description" content="A show">
            <meta property="og:image" content="/img/cover.png">
            <meta property="og:site_name" content="YouTube">
            <link rel="icon" href="/favicon.png">
            </head></html>
        "#;
        let p = parse_preview(html, &base());
        assert_eq!(p.title.as_deref(), Some("Rick & Morty"));
        assert_eq!(p.site_name.as_deref(), Some("YouTube"));
        assert_eq!(
            p.image.as_deref(),
            Some("https://example.com/img/cover.png")
        );
        assert_eq!(
            p.favicon.as_deref(),
            Some("https://example.com/favicon.png")
        );
        assert_eq!(p.description.as_deref(), Some("A show"));
    }

    #[test]
    fn falls_back_to_title_and_host() {
        let html = "<html><head><title>Just a title</title></head></html>";
        let p = parse_preview(html, &base());
        assert_eq!(p.title.as_deref(), Some("Just a title"));
        assert_eq!(p.site_name.as_deref(), Some("example.com"));
        assert_eq!(p.image, None);
        assert_eq!(
            p.favicon.as_deref(),
            Some("https://example.com/favicon.ico")
        );
    }

    #[test]
    fn twitter_tags_are_a_fallback() {
        let html = r#"<meta name="twitter:title" content="Tw"><meta name="twitter:image" content="https://cdn.x/y.png">"#;
        let p = parse_preview(html, &base());
        assert_eq!(p.title.as_deref(), Some("Tw"));
        assert_eq!(p.image.as_deref(), Some("https://cdn.x/y.png"));
    }

    #[test]
    fn resolves_relative_and_protocol_relative_urls() {
        let b = base();
        assert_eq!(b.resolve("/x.png"), "https://example.com/x.png");
        assert_eq!(b.resolve("//cdn.com/x.png"), "https://cdn.com/x.png");
        assert_eq!(b.resolve("x.png"), "https://example.com/a/x.png");
        assert_eq!(b.resolve("https://z.com/q"), "https://z.com/q");
    }

    #[test]
    fn find_ci_matches_case_insensitively() {
        assert_eq!(find_ci(b"abc</HEAD>xyz", b"</head>"), Some(3));
        assert_eq!(find_ci(b"abc</head>xyz", b"</head>"), Some(3));
        assert_eq!(find_ci(b"no closing tag here", b"</head>"), None);
        assert_eq!(find_ci(b"", b"</head>"), None);
    }

    #[tokio::test]
    async fn ssrf_guard_rejects_loopback_and_private() {
        assert!(
            validate_public_http_url("http://localhost/x", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("http://127.0.0.1/x", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("http://10.0.0.5/x", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("http://192.168.1.1/x", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("http://169.254.1.1/x", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("http://[::1]/x", false)
                .await
                .is_err()
        );
        // Non-http schemes are refused regardless.
        assert!(
            validate_public_http_url("file:///etc/passwd", false)
                .await
                .is_err()
        );
        assert!(
            validate_public_http_url("ftp://example.com/x", false)
                .await
                .is_err()
        );
    }

    #[tokio::test]
    async fn ssrf_guard_allows_private_when_opted_in() {
        assert!(
            validate_public_http_url("http://127.0.0.1:8080/x", true)
                .await
                .is_ok()
        );
    }

    #[test]
    fn base64_matches_reference_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        // Non-ASCII bytes exercise the top of the alphabet (+, /).
        assert_eq!(base64_encode(&[0xFB, 0xFF, 0xBF]), "+/+/");
    }

    #[test]
    fn decodable_mime_trusts_known_content_types() {
        assert_eq!(decodable_image_mime("image/png", b""), Some("image/png"));
        assert_eq!(
            decodable_image_mime("image/jpeg; charset=binary", b""),
            Some("image/jpeg")
        );
        assert_eq!(decodable_image_mime("IMAGE/WEBP", b""), Some("image/webp"));
        // Formats Flutter can't decode are rejected so the caller keeps the URL.
        assert_eq!(decodable_image_mime("image/x-icon", b""), None);
        assert_eq!(decodable_image_mime("image/svg+xml", b"<svg/>"), None);
    }

    /// Minimal HTTP/1.1 server: serves `page_html` at `/` and `favicon_bytes`
    /// (as image/png) at `/fav.png`. Returns its base URL. Handles one request
    /// per connection, enough connections for a full unfurl (page + favicon).
    async fn serve_page(page_html: String, favicon_bytes: Vec<u8>) -> String {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let (html, fav) = (page_html.clone(), favicon_bytes.clone());
                tokio::spawn(async move {
                    let mut buf = [0u8; 1024];
                    let n = sock.read(&mut buf).await.unwrap_or(0);
                    let req = String::from_utf8_lossy(&buf[..n]);
                    let wants_favicon = req.starts_with("GET /fav.png");
                    let (ctype, body) = if wants_favicon {
                        ("image/png".to_string(), fav)
                    } else {
                        ("text/html; charset=utf-8".to_string(), html.into_bytes())
                    };
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = sock.write_all(head.as_bytes()).await;
                    let _ = sock.write_all(&body).await;
                    let _ = sock.flush().await;
                });
            }
        });
        format!("http://{addr}/")
    }

    #[tokio::test]
    async fn preview_inlines_a_png_favicon_as_data_uri() {
        // Bytes only need the PNG magic header, the server labels them image/png
        // and the inliner never decodes, it just base64s.
        let png = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4];
        let html = r#"<html><head><title>T</title><link rel="icon" href="/fav.png"></head></html>"#;
        let base = serve_page(html.to_string(), png.to_vec()).await;

        let p = preview_for(&base, true).await.unwrap();
        let fav = p.favicon.expect("favicon present");
        assert!(fav.starts_with("data:image/png;base64,"), "got {fav}");
        assert_eq!(
            fav,
            format!("data:image/png;base64,{}", base64_encode(&png))
        );
    }

    #[tokio::test]
    async fn preview_keeps_url_when_favicon_missing() {
        // No /fav.png route → the default /favicon.ico 404s → keep the URL, and
        // an .ico wouldn't be inlined even if served (Flutter can't decode it).
        let html = "<html><head><title>T</title></head></html>";
        let base = serve_page(html.to_string(), Vec::new()).await;

        let p = preview_for(&base, true).await.unwrap();
        assert_eq!(p.favicon, Some(format!("{base}favicon.ico")));
    }

    #[test]
    fn decodable_mime_sniffs_when_header_is_wrong() {
        // Servers routinely mislabel favicons; magic bytes win over the header.
        let png = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0, 0];
        assert_eq!(
            decodable_image_mime("application/octet-stream", &png),
            Some("image/png")
        );
        assert_eq!(
            decodable_image_mime("text/plain", &[0xFF, 0xD8, 0xFF, 0]),
            Some("image/jpeg")
        );
        assert_eq!(decodable_image_mime("", b"GIF89a...."), Some("image/gif"));
        // Genuinely unknown bytes stay rejected.
        assert_eq!(decodable_image_mime("", b"not an image"), None);
    }
}
