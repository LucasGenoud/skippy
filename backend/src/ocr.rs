//! Image text recognition: uploaded pictures are read by a self-hosted OCR
//! container (no external AI services) so a photo of a receipt, a whiteboard,
//! or a screenshot can be found later by the words inside it. Optional and
//! enabled the same way as [`crate::transcribe`], set `OCR_URL` and the
//! feature turns on; leave it unset (or unreachable) and it stays off,
//! gracefully, without affecting the rest of the app.
//!
//! The reference service is `hertzg/tesseract-server`, which exposes
//! `POST /tesseract` and answers with the Tesseract process output as JSON.

use std::time::Duration;

use async_trait::async_trait;

/// Image bytes -> the text found in them. A trait so tests can inject a
/// deterministic fake instead of standing up an OCR container.
#[async_trait]
pub trait ImageOcr: Send + Sync {
    async fn recognize(&self, image: Vec<u8>, filename: &str) -> anyhow::Result<String>;
}

/// Ceiling on stored recognized text. A dense page of prose is a few thousand
/// characters; past that the tail is almost always noise from a photo's
/// background, and it would ride along in every note payload.
pub const OCR_TEXT_LIMIT: usize = 4000;

/// Image types worth sending to Tesseract. Deliberately an allowlist rather
/// than `image/*`: SVG is a document format with no raster to read, and
/// camera formats Leptonica cannot decode (HEIC) would only produce failures.
pub const OCR_MIME_TYPES: &[&str] = &[
    "image/avif",
    "image/bmp",
    "image/gif",
    "image/jpeg",
    "image/png",
    "image/tiff",
    "image/webp",
];

/// Whether an attachment of this MIME type should be read for text.
pub fn is_ocr_candidate(mime: &str) -> bool {
    let essence = mime.split(';').next().unwrap_or_default().trim();
    OCR_MIME_TYPES
        .iter()
        .any(|candidate| essence.eq_ignore_ascii_case(candidate))
}

/// Talks to a Tesseract HTTP service.
pub struct TesseractService {
    base_url: String,
    /// Tesseract language packs to use, e.g. `eng` or `fra+eng`. Which packs
    /// exist is a property of the OCR image, so this is operator
    /// configuration (`OCR_LANGUAGES`), not a per-user setting.
    languages: String,
    client: reqwest::Client,
}

/// How many times the startup probe is retried, and how long it waits between
/// attempts. Compose starts the OCR container alongside this process rather
/// than before it, so a first refusal usually means "not listening yet", not
/// "not there".
const PROBE_ATTEMPTS: usize = 3;
const PROBE_RETRY_DELAY: Duration = Duration::from_secs(2);

impl TesseractService {
    /// Connect and probe the service so an unreachable OCR server disables the
    /// feature at startup rather than failing every upload later. Any HTTP
    /// response means the server is up; only a transport error is "down".
    pub async fn connect(url: &str, languages: &str) -> anyhow::Result<Self> {
        let base_url = url.trim_end_matches('/').to_string();
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(120))
            .build()?;
        let mut last_error = None;
        for attempt in 0..PROBE_ATTEMPTS {
            if attempt > 0 {
                tokio::time::sleep(PROBE_RETRY_DELAY).await;
            }
            match client
                .get(&base_url)
                .timeout(Duration::from_secs(5))
                .send()
                .await
            {
                Ok(_) => {
                    return Ok(Self {
                        base_url,
                        languages: languages.to_string(),
                        client,
                    });
                }
                Err(e) => last_error = Some(e),
            }
        }
        Err(anyhow::anyhow!(
            "ocr unreachable at {base_url} after {PROBE_ATTEMPTS} attempts: {}",
            last_error.expect("a failed probe records its error")
        ))
    }
}

#[async_trait]
impl ImageOcr for TesseractService {
    async fn recognize(&self, image: Vec<u8>, filename: &str) -> anyhow::Result<String> {
        let part = reqwest::multipart::Part::bytes(image)
            .file_name(filename.to_string())
            .mime_str("application/octet-stream")?;
        let options = serde_json::json!({
            "languages": self.languages.split('+').collect::<Vec<_>>(),
        });
        let form = reqwest::multipart::Form::new()
            .text("options", options.to_string())
            .part("file", part);
        let response = self
            .client
            .post(format!("{}/tesseract", self.base_url))
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;
        Ok(clean_ocr_text(&parse_ocr_reply(&response.text().await?)))
    }
}

/// Pull the recognized text out of an OCR service reply.
///
/// `hertzg/tesseract-server` answers `{"data": {"stdout": "..."}}`; other
/// small OCR servers answer `{"result": "..."}` or plain text. Accepting all
/// three costs a few lines and means swapping the container does not require
/// a code change.
fn parse_ocr_reply(body: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else {
        return body.to_string();
    };
    [
        value["data"]["stdout"].as_str(),
        value["text"].as_str(),
        value["result"].as_str(),
        value["data"].as_str(),
    ]
    .into_iter()
    .flatten()
    .next()
    // Valid JSON in a shape we don't know: no text rather than a stringified
    // object, which would poison the index with braces and field names.
    .unwrap_or_default()
    .to_string()
}

/// Normalize recognized text for storage.
///
/// Every consumer is a matcher (substring search on the client, the embedder
/// on the server), never a reader, so the page's line breaks are only in the
/// way: they would stop `"total due"` from matching a receipt that wraps
/// between the two words. Runs of whitespace collapse to single spaces, and
/// the result is capped at [`OCR_TEXT_LIMIT`].
fn clean_ocr_text(text: &str) -> String {
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= OCR_TEXT_LIMIT {
        return collapsed;
    }
    collapsed.chars().take(OCR_TEXT_LIMIT).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_text_out_of_every_supported_reply_shape() {
        assert_eq!(
            parse_ocr_reply(r#"{"data":{"exit_code":0,"stdout":"MILK 3.20","stderr":""}}"#),
            "MILK 3.20"
        );
        assert_eq!(parse_ocr_reply(r#"{"result":"MILK 3.20"}"#), "MILK 3.20");
        assert_eq!(parse_ocr_reply("MILK 3.20"), "MILK 3.20");
    }

    #[test]
    fn an_unknown_json_shape_yields_no_text_rather_than_its_own_structure() {
        // Indexing `{"error": "no language pack"}` would make every image
        // match a search for "error".
        assert_eq!(parse_ocr_reply(r#"{"error":"no language pack"}"#), "");
    }

    #[test]
    fn layout_whitespace_collapses_so_phrases_survive_line_breaks() {
        assert_eq!(
            clean_ocr_text("  TOTAL\n  DUE\t\t42.00 \n\n"),
            "TOTAL DUE 42.00"
        );
    }

    #[test]
    fn recognized_text_is_capped() {
        let long = "word ".repeat(2000);
        let cleaned = clean_ocr_text(&long);
        assert_eq!(cleaned.chars().count(), OCR_TEXT_LIMIT);
    }

    #[test]
    fn only_raster_images_are_offered_to_the_engine() {
        assert!(is_ocr_candidate("image/png"));
        assert!(is_ocr_candidate("image/JPEG"));
        assert!(is_ocr_candidate("image/jpeg; charset=binary"));
        // A document format with no raster, and formats Leptonica cannot read.
        assert!(!is_ocr_candidate("image/svg+xml"));
        assert!(!is_ocr_candidate("image/heic"));
        assert!(!is_ocr_candidate("application/pdf"));
        assert!(!is_ocr_candidate("audio/webm"));
    }
}
