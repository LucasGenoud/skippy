//! Integration tests for the HTTP API, one module per area.
//! The shared harness (in-memory app, request helpers, fakes) lives in
//! [`helpers`].

mod helpers;

mod attachments;
mod audio;
mod auth;
mod chat;
mod checklist_history;
mod cors;
mod events;
mod labels;
mod llm;
mod notes;
mod notify;
mod ocr;
mod search;
mod settings;
mod share_links;
mod sharing;
mod stages;
mod unfurl;
mod versions;
mod workspaces;
