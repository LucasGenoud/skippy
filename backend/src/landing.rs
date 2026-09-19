//! Small public pages served by the binary when `LANDING_PAGE` is enabled.

use axum::response::Html;

const GITHUB_URL: &str = "https://github.com/LucasGenoud/skippy";

const STYLE: &str = r#"
:root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; color: #202124; background: #faf9f6; }
* { box-sizing: border-box; }
body { margin: 0; line-height: 1.55; }
a { color: inherit; }
nav, main, footer { width: min(100% - 2rem, 920px); margin: auto; }
nav { display: flex; justify-content: space-between; align-items: center; padding: 1.25rem 0; }
.brand { font-weight: 700; text-decoration: none; }
.nav-links { display: flex; gap: 1rem; }
.nav-links a { color: #5f6368; text-decoration: none; }
main { padding: 4rem 0 5rem; }
h1 { max-width: 720px; font-size: clamp(2.4rem, 7vw, 4.6rem); line-height: 1.05; letter-spacing: -0.06em; margin: 0; }
h2 { margin-top: 3rem; letter-spacing: -0.025em; }
.lead { max-width: 640px; font-size: 1.2rem; color: #5f6368; }
.actions { display: flex; flex-wrap: wrap; gap: .75rem; margin: 2rem 0 4rem; }
.button { background: #1f6f54; border: 1px solid #1f6f54; border-radius: .45rem; color: white; padding: .7rem 1rem; text-decoration: none; }
.button.secondary { background: transparent; color: #1f6f54; }
.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
.card { border: 1px solid #dedbd4; border-radius: .5rem; padding: 1.1rem; background: #fff; }
.card h2 { margin: 0 0 .4rem; font-size: 1rem; }
.card p { margin: 0; color: #5f6368; }
.details { max-width: 720px; }
.shots { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 1rem; margin-top: 1.5rem; }
.shot { overflow: hidden; border: 1px solid #dedbd4; border-radius: .5rem; background: #fff; }
.shot img { display: block; width: 100%; }
pre { overflow-x: auto; padding: 1rem; border: 1px solid #dedbd4; border-radius: .5rem; background: #f3f1ec; line-height: 1.45; }
code { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: .7rem; text-align: left; vertical-align: top; border-bottom: 1px solid #dedbd4; }
th { font-size: .85rem; color: #5f6368; }
.note { border-left: 3px solid #1f6f54; padding-left: 1rem; color: #5f6368; }
footer { padding-bottom: 2rem; color: #5f6368; font-size: .9rem; }
@media (prefers-color-scheme: dark) { :root { color: #e8e6e1; background: #1d1f1d; } .nav-links a, .lead, .card p, .note, footer, th { color: #b9b7b0; } .card, .shot { background: #252825; border-color: #42453f; } pre { background: #262925; border-color: #42453f; } th, td { border-color: #42453f; } .button.secondary { color: #78c6a5; } }
@media (max-width: 650px) { main { padding-top: 2.5rem; } .cards, .shots { grid-template-columns: 1fr; } }
"#;

/// The Flutter app stays at `/` unless `LANDING_PAGE` is explicitly enabled.
pub fn enabled(value: Option<&str>) -> bool {
    matches!(
        value.map(|value| value.trim().to_ascii_lowercase()),
        Some(value) if matches!(value.as_str(), "1" | "true" | "on" | "yes")
    )
}

pub async fn home() -> Html<String> {
    page(
        "Skippy",
        r#"
<main>
  <p class="note">Private notes on your own server.</p>
  <h1>Keep notes simple.</h1>
  <p class="lead">Skippy is a cross-platform notes app for writing, organising, sharing, and finding the things you need.</p>
  <p class="actions"><a class="button" href="/app/">Open Skippy</a><a class="button secondary" href="/setup">Set up your server</a></p>
  <section class="cards" aria-label="Features">
    <article class="card"><h2>Write</h2><p>Text, Markdown, checklists, audio, files, and links in one place.</p></article>
    <article class="card"><h2>Organise</h2><p>Workspaces, collections, labels, boards, reminders, and search.</p></article>
    <article class="card"><h2>Share</h2><p>Work together in real time, with offline edits that sync later.</p></article>
  </section>
  <section class="details">
    <h2>Designed for everyday notes.</h2>
    <p>Use a grid, list, or board to keep work visible. Add reminders, labels, attachments, shared workspaces, and public read-only links when you need them.</p>
    <p>Skippy is a Flutter client backed by a Rust and SQLite server. Changes are saved locally first and sync after a connection returns. Transcription, image text recognition, semantic search, and AI tools are optional.</p>
  </section>
  <section aria-label="Screenshots">
    <h2>See it in use.</h2>
    <div class="shots">
      <figure class="shot"><img src="/screenshots/skippy-desktop-masonry.png" alt="Desktop notes grid"></figure>
      <figure class="shot"><img src="/screenshots/skippy-desktop-board-features.png" alt="Desktop board"></figure>
      <figure class="shot"><img src="/screenshots/skippy-iphone-editor-mockup.png" alt="iPhone note editor"></figure>
    </div>
  </section>
</main>
"#,
    )
}

pub async fn setup() -> Html<String> {
    page(
        "Set up Skippy",
        r#"
<main>
  <p class="note">Self-hosting guide</p>
  <h1>Run Skippy with Docker.</h1>
  <p class="lead">The standard setup is one container and one persistent volume. Docker and Docker Compose are the only prerequisites.</p>

  <h2>1. Create docker-compose.yml</h2>
  <pre><code>services:
  server:
    image: ghcr.io/lucasgenoud/skippy:latest
    ports:
      - "8787:8787"
    environment:
      PUBLIC_URL: https://notes.example.com
    volumes:
      - app_data:/data
    restart: unless-stopped

volumes:
  app_data:</code></pre>

  <h2>2. Start it</h2>
  <pre><code>docker compose up -d</code></pre>
  <p>Open <code>https://notes.example.com</code>, or <code>http://localhost:8787</code> when running locally.</p>

  <h2>Optional services</h2>
  <p>Clone the repository when you want its ready-made Compose variants.</p>
  <pre><code>git clone https://github.com/LucasGenoud/skippy.git
cd skippy

# Add audio transcription and image text recognition
docker compose -f docker-compose.yml -f docker-compose.simple.yml up -d

# Also use Garage for S3-compatible attachment storage
docker compose -f docker-compose.yml -f docker-compose.simple.yml -f docker-compose.all.yml up -d</code></pre>

  <h2>Environment variables</h2>
  <table>
    <thead><tr><th>Variable</th><th>Purpose</th><th>Default</th></tr></thead>
    <tbody>
      <tr><td><code>PUBLIC_URL</code></td><td>Public address of this server. It sets the browser origin and password-reset links.</td><td>Unset</td></tr>
      <tr><td><code>LANDING_PAGE</code></td><td>Set to <code>true</code> to show these public pages and serve the app from <code>/app/</code>.</td><td><code>false</code></td></tr>
      <tr><td><code>STORAGE</code></td><td>Attachment storage: <code>disk</code> or <code>s3</code>. S3 also needs <code>S3_URL</code>, <code>S3_ACCESS_KEY</code>, and <code>S3_SECRET_KEY</code>.</td><td><code>disk</code></td></tr>
      <tr><td><code>WHISPER_URL</code></td><td>Optional Whisper service for audio transcription.</td><td>Unset</td></tr>
      <tr><td><code>OCR_URL</code></td><td>Optional Tesseract service for finding text in images. Use <code>OCR_LANGUAGES</code> to select installed language packs.</td><td>Unset</td></tr>
      <tr><td><code>EMBED_URL</code></td><td>Optional OpenAI-compatible embeddings endpoint for semantic search.</td><td>Unset</td></tr>
      <tr><td><code>LLM_*</code></td><td>Optional server-managed AI settings. <code>LLM_BASE_URL</code>, <code>LLM_API_KEY</code>, and <code>LLM_MODEL</code> configure the provider; feature flags control labels, chat, and writing.</td><td>Unset</td></tr>
      <tr><td><code>SMTP_*</code></td><td>Optional mail server settings for email reminders and password reset.</td><td>Unset</td></tr>
    </tbody>
  </table>
  <p class="note">Set variables in the Compose <code>environment</code> section or a <code>.env</code> file. For example, add <code>LANDING_PAGE=true</code> to <code>.env</code> to show the landing and setup pages.</p>
</main>
"#,
    )
}

fn page(title: &str, content: &str) -> Html<String> {
    Html(format!(
        r#"<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="description" content="Skippy is a self-hosted notes app."><title>{title}</title><style>{STYLE}</style></head><body>
<nav><a class="brand" href="/">Skippy</a><span class="nav-links"><a href="/setup">Set up</a><a href="{GITHUB_URL}" rel="noreferrer">GitHub</a></span></nav>
{content}
<footer>Skippy is open source and self-hosted.</footer>
</body></html>"#,
    ))
}

#[cfg(test)]
mod tests {
    use super::enabled;

    #[test]
    fn landing_page_is_disabled_unless_explicitly_enabled() {
        assert!(!enabled(None));
        assert!(!enabled(Some("false")));
        assert!(enabled(Some("yes")));
        assert!(enabled(Some("ON")));
    }
}
