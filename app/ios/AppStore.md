# App Store listing

Everything App Store Connect asks for, ready to paste. Character limits are
Apple's.

## App information

- Name (30): `Skippy Notes` (`Skippy` alone is likely taken)
- Subtitle (30): `Notes that sync, work offline`
- Bundle ID: `com.lucasgenoud.skippy`
- SKU: `skippy-ios`
- Primary category: Productivity
- Secondary category: Utilities
- Content rights: does not contain third-party content
- Age rating: answer "None" to every question, "No" to unrestricted web
  access, user-generated content sharing: "No" (notes are private to the
  people they are shared with). Result: 4+.
- Price: Free

## URLs

- Privacy policy: https://docs.skippy-notes.com/privacy/
- Support: https://github.com/LucasGenoud/skippy/issues
- Marketing: https://docs.skippy-notes.com/

## Version text

Promotional text (170):

```
Notes, checklists, boards, and audio, synced across your devices. Use the
free public server or run your own.
```

Description (4000):

```
Skippy is a notes app for everything you need to remember: quick thoughts,
nested checklists, Markdown documents, audio memos, photos, and files.

Organize your way
- Arrange notes as a grid, a list, or a Kanban board
- Group them into workspaces and collections, with shared labels
- Link notes to each other and see what links back

Work offline
- Every edit is saved on the device first and syncs when you reconnect
- Changes from other devices and collaborators appear live

Collaborate
- Share a workspace or a single note with other people
- Version history lets you look back and restore earlier text

Never forget
- Reminders at a time, on a checklist item, or when you arrive at or leave a
  place
- Home-screen widgets and the share sheet put notes one tap away

Find anything
- Search note text, including text recognized in images
- Optional AI tools to label, rewrite, and chat with your notes, using the
  provider you choose

Your data, your server
- Use the free public server, or self-host Skippy with Docker and point the
  app at your own instance
- No ads, no analytics, no tracking
```

Keywords (100):

```
notes,checklist,todo,kanban,markdown,reminders,self-hosted,offline,sync,keep,memo,lists
```

What's New (first version): `First release on the App Store.`

Copyright: `2026 Lucas Genoud`

## App Review information

- Sign-in required: yes
- Demo account: create one on https://skippy-notes.com with sample notes, then
  enter its email and password here. Do not use your own account.
- Contact: your name, phone, and email

Notes for the reviewer:

Answers Guideline 2.1 (Information Needed). Attach the screen recording to
the reply, then paste this into the Notes field. Fill in the bracketed
parts before sending.

```
1. SCREEN RECORDING
Attached, recorded on an [iPhone model] running iOS [version]. It shows:
launching the app, creating an account, creating a text note, a checklist
and an audio note, setting a reminder, sharing a note with a second
account, leaving that shared note from the second account, signing out,
signing in, and deleting the account (Settings > Account > Delete account).
The app has no paid content or in-app purchases.

2. PURPOSE AND AUDIENCE
Skippy is a notes app for individuals and small groups (families,
friends, small teams) who want their notes, checklists and reminders on
all their devices, including while offline. Every edit is saved on the
device first and syncs when a connection returns. Notes can be organized
as a grid, a list or a Kanban board, and shared with people the user
chooses. The server is open source, so users who want full control of
their data can run their own instead of the public one.

3. SETUP AND MAIN FEATURES
No setup is needed: the app connects to the public server
https://skippy-notes.com by default.
Demo account: [email] / [password]. It already holds sample notes.
- Create a note: the bar at the top of the grid (text, checklist,
  Markdown); the microphone button records an audio note.
- Reminders: open a note, tap Remind me. Place reminders: Settings >
  Reminders > Saved places.
- Views: each collection's settings choose grid, list or board.
- Sharing: open a note > Share, enter another account's email.
- Search: the search field in the top bar.
- Account deletion: Settings > Account > Delete account.

4. EXTERNAL SERVICES
- Skippy server at skippy-notes.com, operated by the developer: accounts,
  sync, file storage. Authentication is the app's own email and password;
  no third-party sign-in.
- OpenStreetMap: map tiles when picking a place for a location reminder.
- AI features (labeling, rewriting, chat) are optional, off until a user
  enters their own OpenAI-compatible provider and key in Settings > AI &
  search. [Confirm: the public server provides no AI provider itself.]
- Reminder delivery channels (ntfy, Telegram, email) are optional and
  only used if the user configures one.
- Link previews are fetched by the Skippy server from the linked page.
No payment processors, analytics, advertising or tracking services.

5. REGIONS
The app works the same in every region. Content and features do not vary
by country.

6. REGULATED INDUSTRY / THIRD-PARTY MATERIAL
Not applicable. Skippy is not in a regulated industry and contains no
third-party content; users only see notes they wrote or that someone
shared with them.

PERMISSIONS
Location (Always): used only for reminders the user attaches to a saved
place. The app registers geofences for those places so an arrival or
departure reminder fires while the app is closed. No location is
collected otherwise. Microphone: audio notes. Camera and photos:
attaching images.

USER CONTENT
There is no public feed, directory or discovery. A note is visible only
to its author and to people the author adds by email address. Anyone who
receives a shared note or workspace can leave it at any time (Share >
Leave note, or Workspace settings > Leave workspace), which removes it
from their account.
```

## App Privacy

Tracking: no. For each type below: linked to the user, not used for
tracking, purpose App Functionality only.

| Category | Type | Why |
| --- | --- | --- |
| Contact Info | Name, Email Address | Account |
| User Content | Photos or Videos, Audio Data, Other User Content | Notes and attachments |
| Location | Precise Location | Places saved for reminders |
| Identifiers | User ID | Account |

Not collected: health, financial, contacts, browsing or search history,
usage data, diagnostics, purchases.

## Export compliance

Declared in `Runner/Info.plist` (`ITSAppUsesNonExemptEncryption` false): the
app only uses HTTPS.

## Screenshots

In `screenshots/`, light mode, captured from the simulators with a demo
account. Upload in this order:

- iPhone with Dynamic Island, medium display (1206 x 2622):
  `iphone-1-grid.png`, `iphone-2-checklist.png`, `iphone-3-chat.png`
- iPad 13" (2064 x 2752): `ipad-1-grid.png`, `ipad-2-editor.png`,
  `ipad-3-board.png`

Header and Search Results (optional), in `screenshots/marketing/`:

- Header (3840 x 1646): `header.png`
- Search Results (1920 x 1280): `search-results.png`
