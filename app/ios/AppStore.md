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

```
Skippy is a notes app. It connects to https://skippy-notes.com by default;
no server setup is needed. Sign in with the demo account above, or create
an account on the sign-in screen.

Location (Always): used only for reminders the user attaches to a saved
place (Settings > Reminders > Saved places). The app registers geofences for those
places so an arrival or departure reminder fires while the app is closed.
No location is collected otherwise.

Microphone: audio notes. Camera and photos: attaching images.

Account deletion: Settings > Account > Delete account.
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

In `screenshots/`, captured from the simulators against a local server with
a demo account. Upload in this order:

- iPhone 6.9" (1320 x 2868): `iphone-1-grid.png`, `iphone-2-dark.png`
- iPad 13" (2064 x 2752): `ipad-1-grid.png`, `ipad-2-board.png`,
  `ipad-3-dark.png`
