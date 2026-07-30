//! Audio transcription: recorded clips are transcribed locally (no external
//! AI services) by a self-hosted Whisper container. Optional and enabled the
//! same way as [`crate::search`], set `STICKY_NOTES_WHISPER_URL` and the
//! feature turns on; leave it unset (or unreachable) and it stays off,
//! gracefully, without affecting the rest of the app.
//!
//! The reference service is `onerahmet/openai-whisper-asr-webservice`, which
//! decodes with ffmpeg, so browser `audio/webm;opus` clips work as-is, and
//! exposes `POST /asr`.

use std::time::Duration;

use async_trait::async_trait;

/// Audio bytes -> transcript text. A trait so tests can inject a deterministic
/// fake instead of standing up a Whisper container.
#[async_trait]
pub trait Transcriber: Send + Sync {
    async fn transcribe(&self, audio: Vec<u8>, filename: &str) -> anyhow::Result<String>;
}

/// Talks to a Whisper ASR web service over HTTP.
pub struct WhisperService {
    base_url: String,
    client: reqwest::Client,
}

impl WhisperService {
    /// Connect and probe the service so an unreachable Whisper disables the
    /// feature at startup rather than failing every recording later. Any HTTP
    /// response means the server is up; only a transport error is "down".
    pub async fn connect(url: &str) -> anyhow::Result<Self> {
        let base_url = url.trim_end_matches('/').to_string();
        // Transcription of a long clip can take a while; keep the ceiling high.
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(600))
            .build()?;
        client
            .get(&base_url)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| anyhow::anyhow!("whisper unreachable at {base_url}: {e}"))?;
        Ok(Self { base_url, client })
    }
}

#[async_trait]
impl Transcriber for WhisperService {
    async fn transcribe(&self, audio: Vec<u8>, filename: &str) -> anyhow::Result<String> {
        let part = reqwest::multipart::Part::bytes(audio)
            .file_name(filename.to_string())
            .mime_str("application/octet-stream")?;
        let form = reqwest::multipart::Form::new().part("audio_file", part);
        // output=txt returns just the transcript as plain text.
        let url = format!("{}/asr?encode=true&task=transcribe&output=txt", self.base_url);
        let response = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .await?
            .error_for_status()?;
        Ok(response.text().await?.trim().to_string())
    }
}
