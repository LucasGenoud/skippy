# AGENTS.md

## Purpose and scope

This file is the working map for agents modifying this repository. It applies to the whole tree unless a more specific `AGENTS.md` is added below it.

The product is named Skippy in the UI and packages; the repository is named `sticky_notes`. It is a Flutter web/iOS/Android client backed by a Rust axum API with SQLite persistence. The defining implementation constraints are optimistic client interactions, offline-capable writes, participant-scoped data access, and optional self-hosted AI services.

Before changing code:

1. Read the root `README.md` for supported behavior and setup.
2. Run `git status --short`; the worktree may contain user or another agent's changes. Preserve unrelated edits.
3. Trace the relevant contract across both client and server when changing API data or behavior.

## Quick verification

Run commands from the indicated package directory:

```sh
cd backend
cargo test
cargo clippy --all-targets -- -D warnings

cd ../app
flutter analyze
flutter test
```

For a focused iteration, pass a Rust test filter or a Flutter test file, for example:

```sh
cd backend && cargo test --test api versions
cd app && flutter test test/notes_store_test.dart
```

Some backend integration tests start local HTTP listeners for unfurl, S3, or service fakes. A restricted execution environment must permit loopback sockets for those tests.

Format touched Dart files with `dart format`. Format touched Rust files with `cargo fmt -- <files>` or an equivalent focused command. A whole-tree `cargo fmt --check` may expose pre-existing formatting drift; do not mix unrelated formatting churn into a focused change.

## Runtime architecture

### Client startup and state

`app/lib/main.dart` creates the long-lived `ApiClient`, `AuthStore`, `LinkPreviewCache`, and platform share intake. Once authenticated, it creates user-scoped `NotesStore` and `SettingsStore` instances.

`AuthStore` restores a token and cached user at startup. If the server is unavailable, a previously authenticated user can enter the app from the local cache. Do not turn initial connectivity into a hard startup dependency.

`NotesStore` is the central client domain store. Mutations are optimistic and are represented by serializable pending operations. The store persists note metadata and its operation queue through `PrefsLocalCache`, retries transient failures, drops permanent client failures, and refetches after WebSocket change notifications. Pure note transformations are split into:

- `state/note_collection.dart`: sorting, filtering, searching, and view selection.
- `state/board_layout.dart`: grouping notes into board columns.
- `state/note_conversion.dart`: conversion between text, markdown, and checklist content.
- `state/pending_operation.dart`: persisted optimistic operation types and JSON encoding.

The WebSocket is a change nudge, not a stream of note patches. Multiple notifications are debounced and lead to a refetch. Last-write-wins remains the collaboration model.

### Server startup and requests

`backend/src/main.rs` reads configuration and wires the SQLite repository, disk or S3 file store, WebSocket hub, managed settings, reminder scheduler, optional embedding service, optional Whisper client, and static Flutter web serving.

`backend/src/lib.rs` defines `AppState` and `build_app`. Integration tests reuse this router with in-memory SQLite and deterministic fakes.

Normal request flow is:

```text
axum route -> feature handler -> Repository/FileStore/service -> response
                                      |
                                      +-> background indexing, labeling,
                                          notification, transcription, or WS nudge
```

Keep slow or optional work off the response latency path when the existing behavior does so. Content-changing note operations can schedule versioning, semantic indexing, automatic labeling, and collaborator notifications. Pure organization changes should not accidentally invoke all content pipelines.

Notes chat uses one WebSocket connection per turn. The assistant router can answer directly, search notes, or plan a write. Create/append actions should reuse the same post-write pipelines as ordinary note edits instead of implementing a second consistency path.

## Repository map

### Root and deployment

- `README.md`: product behavior, local setup, API sketch, and design trade-offs.
- `Dockerfile`: builds Flutter web, compiles the Rust binary, and produces the full-stack runtime image.
- `docker-compose.yml`: app, Whisper, and Garage services. It does not define Watchtower.
- `garage.toml`: bundled S3-compatible Garage configuration.
- `.forgejo/workflows/build.yml`: full-stack image build and registry push on the `homeserver-runner` label.
- `docs/DEPLOY.md`: Forgejo, registry, homeserver, and rollback notes.
- `docs/superpowers/`: historical feature designs and plans; useful context, not the source of truth when code differs.

### Backend

- `backend/src/main.rs`: process composition and environment-dependent service construction.
- `backend/src/lib.rs`: shared state, middleware, route registration, static web fallback.
- `backend/src/config.rs`: managed setting descriptors and environment parsing.
- `backend/src/models.rs`: domain structures plus HTTP request/response payloads.
- `backend/src/auth.rs`: password hashing, token authentication, and authenticated-user extraction.
- `backend/src/error.rs`: API error shape and HTTP status conversion.
- `backend/src/handlers/mod.rs`: feature exports and shared handler helpers.
- `backend/src/handlers/auth.rs`: registration, login, logout, current user.
- `backend/src/handlers/notes.rs`: note CRUD, reorder, trash purge, checklist history, and note mutation orchestration.
- `backend/src/handlers/versions.rs`: version timeline and restores.
- `backend/src/handlers/attachments.rs`: multipart upload, signed serving, ranges, transcription trigger, deletion.
- `backend/src/handlers/sharing.rs`: collaborator lookup, add/remove, and permission rules.
- `backend/src/handlers/workspaces.rs`: workspace CRUD, membership, and the default workspace every account starts with.
- `backend/src/handlers/labels.rs`: workspace labels and note-label membership.
- `backend/src/handlers/stages.rs`: workspace board columns. A near-copy of `labels.rs` on purpose; see the stages/labels contract below before merging the two.
- `backend/src/handlers/settings.rs`: opaque per-user settings document and managed descriptors.
- `backend/src/handlers/search.rs`: semantic query, stats, and background reindex endpoints.
- `backend/src/handlers/chat.rs`: streaming note-chat WebSocket and optional writes.
- `backend/src/handlers/events.rs`: ordinary change-event WebSocket.
- `backend/src/handlers/unfurl.rs`: authenticated link-preview endpoint and cache integration.
- `backend/src/handlers/probes.rs`: tests for unsaved LLM and notification configurations.
- `backend/src/handlers/background.rs`: shared post-write jobs for versions, search, auto-labeling, and notifications.
- `backend/src/store/mod.rs`: `Repository` contract. This is the persistence seam and permission-aware query boundary.
- `backend/src/store/sqlite.rs`: SQLite repository implementation and high-level query methods.
- `backend/src/store/sqlite_schema.rs`: current clean-break schema creation.
- `backend/src/store/sqlite_rows.rs`: SQL row structs and conversion into domain models.
- `backend/src/files.rs`: independent `FileStore` seam, disk and S3 implementations, signing helpers.
- `backend/src/search.rs`: embeddings API client, sqlite-vec tables, indexing and search implementation.
- `backend/src/transcribe.rs`: Whisper service interface and HTTP implementation.
- `backend/src/assist.rs`: effective LLM settings, prompts, assistant routing, and structured-output parsing.
- `backend/src/llm.rs`: OpenAI-compatible completion and streaming client.
- `backend/src/notify.rs`: reminder scheduler and ntfy/Telegram connectors.
- `backend/src/unfurl.rs`: outbound URL validation, SSRF protections, fetching, and metadata parsing.
- `backend/src/ws.rs`: per-user event fan-out hub.
- `backend/tests/api/main.rs`: modular API integration test entry point.
- `backend/tests/api/helpers.rs`: real-router harness and deterministic fake services.
- `backend/tests/api/*.rs`: behavior grouped by API feature.
- `backend/tests/api/stages.rs`: board columns, including the rules that keep them independent of labels.
- `backend/tests/s3.rs`: S3 file-store behavior against a local fake server.

### Flutter client

- `app/lib/main.dart`: dependency wiring, authentication gate, user-scoped stores, theme binding.
- `app/lib/api/api_client.dart`: `Api` abstraction, HTTP implementation, uploads, downloads, and WebSockets. UI/state code should depend on `Api`, not directly on HTTP.
- `app/lib/models/note.dart`: notes, checklist items, labels, collaborators, versions, attachments, settings-related value types.
- `app/lib/models/workspace.dart`: workspace and its roster.
- `app/lib/models/chat.dart`: chat frames, citations, tool/write states.
- `app/lib/models/link_preview.dart`: unfurl response and cache model.
- `app/lib/models/notify_channels.dart`: frontend notification connector registry.
- `app/lib/models/search_stats.dart`: semantic index diagnostics.
- `app/lib/state/auth_store.dart`: session restoration, login/register/logout, offline authentication fallback.
- `app/lib/state/notes_store.dart`: optimistic note domain, sync queue, retry, WebSocket refresh, attachments.
- `app/lib/state/settings_store.dart`: defaults, JSON persistence, managed settings, capabilities, and setting mutations.
- `app/lib/state/local_cache.dart`: per-user cached notes and persisted pending operations.
- `app/lib/state/link_preview_cache.dart`: in-memory/client preview cache and fetch coalescing.
- `app/lib/state/share_intake*.dart`: Android/iOS share-sheet payload intake with platform stubs.
- `app/lib/state/editor_history.dart`: editor undo/redo grouping.
- `app/lib/screens/login_screen.dart`: server selection and authentication.
- `app/lib/screens/home_screen.dart`: main coordinator for views, selection, search, reorder, navigation, keyboard shortcuts, and share intake.
- `app/lib/screens/editor_screen.dart`: note-kind editing, drafts, attachments, recording, find-in-note, and save lifecycle.
- `app/lib/screens/history_screen.dart`: version display and restore.
- `app/lib/screens/settings_screen.dart`: settings composition and optional-service probes.
- `app/lib/screens/chat_screen.dart`: streamed notes chat, citations, and write confirmation/result UI.
- `app/lib/widgets/masonry.dart`: custom animated masonry layout and drag reorder.
- `app/lib/widgets/board/`: the board view (side-by-side columns on wide screens, paged on phones), the column picker, and the stage editor.
- `app/lib/widgets/note_card.dart`: card rendering for all note types.
- `app/lib/widgets/animated_checklist.dart`: checklist editing, reordering, checked-section animation, and suggestions.
- `app/lib/widgets/quick_add_bar.dart`: inline text, checklist, and markdown drafts plus image-note creation.
- `app/lib/widgets/editor/`: extracted editor attachment, text-field, and bottom-bar pieces.
- `app/lib/widgets/settings/`: extracted settings sections and shared managed/probe UI.
- `app/lib/widgets/workspace_menu.dart`: workspace switcher, create/rename, roster management, and the move-a-note picker.
- `app/lib/widgets/file_drop*.dart`, `audio_player*.dart`, `audio_recorder*.dart`: conditional web/native implementations.
- `app/lib/util/runtime_config*.dart`, `connectivity*.dart`, `download*.dart`: platform-conditional infrastructure. Keep `dart:html` and `dart:io` out of shared files.
- `app/lib/util/note_export.dart`: JSON, Markdown, and plain-text export.
- `app/lib/util/linkify.dart`, `highlight.dart`, `mime.dart`, `note_image.dart`: pure display/content helpers.
- `app/lib/util/motion.dart`, `snack.dart`, `label_style.dart`: shared UI conventions.
- `app/test/fake_api.dart`: in-memory implementation of the full `Api` seam.
- `app/test/notes_store_test.dart`, `settings_store_test.dart`: state and synchronization coverage.
- `app/test/widget_test.dart` and feature test files: widget and integration-style client behavior.

## Cross-layer contracts and invariants

### Wire models

Rust payloads in `backend/src/models.rs`, Dart models in `app/lib/models`, methods in `ApiClient`, and `FakeApi` form one contract. When a field or endpoint changes, update every affected side and both test suites. Confirm null semantics: omission and explicit `null` are intentionally different for some PATCH fields such as reminders.

Supported note kinds are `text`, `markdown`, `checklist`, and `audio`. Audio transcript state is separately represented as none, pending, done, or failed. Do not infer transcription state only from whether transcript text is empty.

`workspace_id` is optional on note and label creation and resolves to the caller's default workspace; that is a deliberate API default, not a compatibility shim. On the client, a note filed in a workspace the user does not belong to, reached through a per-note share, surfaces in their default workspace; `WorkspaceScope` in `state/note_collection.dart` is the single place that rule lives.

### Permissions and ownership

Every note and label belongs to exactly one workspace. The workspace is the note's sole owner; `notes.created_by` is nullable attribution and grants no lifecycle authority. A participant is a direct collaborator or a member (including the owner) of the workspace holding it, so new note-related queries should go through `participant_ids`/`is_participant` rather than reading `note_shares` directly.

Repository queries are participant-scoped. A non-participant should normally receive not found rather than learning that a note exists. The owning workspace's owner controls destructive sharing and note lifecycle actions, including moving a note between workspaces; members and direct collaborators can edit. Workspaces have an owner plus flat members: only the owner renames, deletes, or changes the roster, and members may leave. Deleting a workspace permanently deletes every note and attachment it contains, regardless of creator; leaving or being removed never moves or deletes workspace-owned notes. Deleting an account deletes its owned workspaces but preserves notes it created in other users' workspaces, clearing creator attribution. A user's default workspace can never be deleted or left while the account exists.

Labels are a workspace's shared taxonomy, not personal state: every member sees and applies the same set. Someone who reached a note through a direct share is not in its workspace, so they see none of its labels and their `label_ids` patch is ignored rather than clearing what members attached. Pin, archive, reminder, color, and custom ordering are shared note state.

Stages (board columns) are shared workspace state too, and are deliberately a separate system from labels: a note carries any number of labels via `note_labels` and at most one stage via `notes.stage_id`, so the exclusivity a board needs is a schema fact rather than a rule the client maintains. The two must stay independent. Do not merge `handlers/stages.rs` into `handlers/labels.rs` or introduce a shared "workspace taxonomy" abstraction, they read alike, and the duplication is the cheaper side of that trade. A patch carrying `stage_id` must never write `note_labels`, and one carrying `label_ids` must never write `stage_id`; `backend/tests/api/stages.rs` pins both directions. Shared code between the two is allowed only over primitives (both resolve a hex colour through `PaletteEntry.hexToColor`), never over each other's types.

A note's stage must belong to the note's workspace. `prune_foreign_stage` is the single-stage counterpart of `prune_foreign_labels` and is what stops a stray or foreign stage id from sticking; a workspace move clears the stage for the same reason it drops the old labels. `stage_position` orders cards within a column and is separate from `position` on purpose, so arranging the board never reshuffles the grid. A move is one patch carrying both `stage_id` and `stage_position`, not a stage change chased by a reorder.

Recheck the entire permission matrix when adding a note-related endpoint. Do not fetch a raw row first and bolt on an inconsistent permission check if an existing participant-scoped repository method can express the operation.

### Mutation side effects

Note content edits drive version capture, semantic reindexing, automatic labeling, collaborator notification, and WebSocket fan-out. Organization-only edits should retain their deliberately smaller side-effect set.

Each note has one embedding in the collection owned by its workspace. Sharing and roster changes do not rewrite embeddings; authorization is rechecked against the relational repository over vector candidates. A note move relocates its vector between workspace collections and must notify the workspace it left, not only the one it joined. Workspace deletion drops its collection and deletes attachment blobs. Version grouping uses an edit-session window, so tests should control timestamps rather than assume every keystroke becomes a version.

Checklist history is recorded on a transition to checked, shared with participants in that note, and capped at 500 records per note.

Client-generated UUIDs allow offline creation. Empty drafts remain local until meaningful text or a file exists. The server rejects reused note ids with 409 Conflict, so preserve the serial queue's create-before-update ordering.

### Settings

The backend stores a per-user opaque JSON document capped at 16 KB. `SettingsStore` supplies defaults and owns client serialization. Adding a setting usually requires changes to defaults, JSON load, `toJson`, mutation methods, UI, and tests.

Managed settings are described by the backend configuration registry. A field can be server-supplied and locked. Secret managed values must be usable by the server but never returned to the client. Backend helpers that compute effective LLM/notification configuration must remain consistent with frontend lock and redaction behavior.

Every notification connector key in `kNotifyChannels` must match a backend connector identifier. Preserve all channel-specific fields when serializing settings, even if their section is collapsed or temporarily disabled.

### Semantic search and chat

Embeddings come from an external OpenAI-compatible API (`STICKY_NOTES_EMBED_URL`), never from a model loaded in-process, keep it that way, since an in-process model dominates the server's memory. The vector width is probed at startup rather than hardcoded, and `{model}:{dims}` is the index signature: change either and `SqliteVectorIndex::connect` drops all workspace collections so startup reindexing re-embeds. sqlite-vec uses one virtual table per workspace and one vector per note. Search/chat select the caller's accessible workspace collections and must still recheck every hit through the repository, especially for direct shares into an otherwise inaccessible workspace. Search is optional; route behavior, `/api/capabilities`, settings visibility, and tests must agree when it is unavailable.

Chat retrieval and writes depend on the same optional embedding and LLM configuration paths. Stream frame types are shared conceptually between `handlers/chat.rs` and `models/chat.dart`; add unknown-frame resilience on the client when extending the protocol.

### Files, previews, and transcription

Attachment metadata lives in SQLite, but bytes live behind `FileStore`. Disk and S3 behavior must remain equivalent. File URLs are signed, expire, and may use range requests; inline media and forced downloads intentionally differ in content disposition. The client limits selected files to 25 MB and the server enforces its own 30 MB ceiling.

Do not cache attachment bytes in shared preferences. The offline cache stores note metadata and signed URLs; URLs may expire and must be refreshed from the API.

Link previews are fetched by the backend. Preserve URL scheme validation, DNS/IP checks, redirect revalidation, response-size limits, timeouts, and the private-host opt-in. Do not move arbitrary URL fetching into the client.

Audio-note creation and retranscription are asynchronous. Keep the note usable while the transcript is pending or failed, and keep transcription failures from rolling back the uploaded clip.

## Common change paths

### Add or change an endpoint

1. Add the handler in the closest `backend/src/handlers` module.
2. Export it from `handlers/mod.rs` if needed and register the route in `backend/src/lib.rs`.
3. Add or change repository/service methods at the appropriate seam.
4. Update the Flutter `Api` interface and `ApiClient` implementation.
5. Update `app/test/fake_api.dart` so frontend tests still compile.
6. Add real-router backend coverage and client coverage for the caller.
7. Update the README API sketch if the endpoint is public and important.

### Add a workspace-scoped concept

Decide first whether it is workspace state (shared by every member, like labels) or per-user state. Workspace state needs a `workspace_id` column, membership-scoped repository queries rather than owner-scoped ones, notification to the whole roster instead of one user, and a client filter through `WorkspaceScope` so switching workspaces switches it.

### Add a persisted note field

1. Update Rust domain and request/update payloads.
2. Update create/update application logic and side-effect classification.
3. Update the `Repository` trait, SQLite schema, SQL statements, row decoding, and tests.
4. Update the Dart model, copy/JSON methods, local cache, API payloads, and `FakeApi`.
5. Update store/UI behavior and both focused and cross-layer tests.

The current workspace-owned schema is a clean break and has no in-place migration layer. Schema changes must update fresh-database creation and compatible backup validation. Never rewrite or delete a developer's local database as part of a code change.

### Add a setting or optional capability

For an ordinary setting, update all `SettingsStore` default/load/save paths and the relevant UI. For a managed setting, also update backend config parsing, descriptors, secret redaction, and effective-value helpers. For an optional service, keep startup wiring, `AppState`, `/api/capabilities`, settings visibility, disabled endpoint behavior, and test fakes aligned.

### Add a platform-specific feature

Use conditional exports with a neutral shared interface plus explicit web/native/stub files. The web build must never resolve `dart:io`; native builds must never require `dart:html`. Existing runtime config, download, connectivity, file-drop, audio, and share-intake modules are the patterns to follow.

### Change notifications or attachments

A notification connector touches the backend `Connector` model, connector builder and probe/scheduler behavior, frontend channel registry/settings serialization, settings UI, and deterministic tests.

An attachment change usually touches upload handlers, metadata persistence, both `FileStore` implementations, URL signing/serving, client URL resolution, editor/card rendering, cleanup, and tests for authorization and ranges.

## Testing guidance

Backend API tests use the real router and in-memory SQLite. Use the fake embedder, Whisper client, LLM client, and notification connectors in `backend/tests/api/helpers.rs`; do not call real providers. Use local deterministic HTTP fixtures for unfurl and S3 behavior.

Frontend tests use `FakeApi`. Store tests should cover optimistic state immediately, eventual server calls, retry/drop policy, queue persistence, and server-refetch reconciliation. Widget tests should avoid timing assumptions when a shared motion duration or debounce helper can be awaited instead.

Place regressions near the layer that owns the rule, then add a cross-layer test when serialization, authorization, or asynchronous side effects are involved. Prefer behavior assertions over implementation-detail assertions.

## Coding and maintenance conventions

- Preserve optimistic UI behavior: network calls should not move onto the direct interaction path without a deliberate product decision.
- Keep `NotesStore`, large screens, and large handlers as coordinators. Extract pure transformations, focused widgets, repository helpers, or background helpers before adding another unrelated responsibility.
- Prefer existing shared UI helpers such as `Motion`, `showAppSnack`, palette/label utilities, and settings section components.
- Return backend failures through `ApiError`; do not expose internal error chains, provider credentials, or managed secrets.
- Treat WebSocket events as invalidation signals unless the protocol is explicitly redesigned on both sides.
- Keep caches user-scoped. Clear or switch them correctly at logout/account/server changes.
- Do not commit generated or runtime data such as `app/build`, `app/.dart_tool`, `backend/target`, SQLite databases, upload directories, logs, or model caches. `Cargo.lock` and `app/pubspec.lock` are intentionally tracked.
- Do not perform broad formatting, dependency upgrades, database deletion, or generated platform rewrites as collateral work.
- Repository documentation should use plain text without emoji.
