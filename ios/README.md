# MyInstants Remote (iPhone)

SwiftUI companion app for the MyInstants Mac app: browse myinstants.com on the phone, tap a button, and the sound plays **on the Mac**.

- Requires the Mac app with **📱 → Allow iPhone remote** turned on, and both devices on the same Wi‑Fi.
- Build with **Xcode 16+**, runs on **iOS 16+**. No third‑party dependencies.
- Install steps and security notes: see [the main README](../README.md#-iphone-remote).

## Layout

| File | What it does |
|---|---|
| `MyInstantsRemoteApp.swift` | App entry; shows Connect, Connecting or the main tabs. |
| `RemoteClient.swift` | HTTP client for the Mac's `remote.js` (PIN in `X-Pin`), pairing, play/stop/volume. |
| `MacBrowser.swift` | Bonjour discovery of `_myinstants._tcp` and resolving it to an IPv4 address. |
| `Models.swift` | Sounds, lists (feeds), categories, colors. |
| `Views/` | Connect + PIN, tab bar, sound grid with glossy buttons, sound page, search, account, player bar. |

## Mac API (`remote.js`)

All requests need the header `X-Pin: <6-digit PIN>`. JSON in and out.

| Request | Does |
|---|---|
| `GET /api/hello` | `{ name, version, loggedIn, volume }` — also used to check the PIN. |
| `GET /api/sounds?path=/en/...&page=N` | A list page, same shape the desktop window gets. |
| `GET /api/instant?page=/en/instant/...` | A sound's own page. |
| `POST /api/play {url, name}` | Plays a myinstants.com sound on the Mac. |
| `POST /api/stop` | Stops playback. |
| `POST /api/volume {volume}` | 0–1. |
| `POST /api/favorite {id, on}` | Adds/removes a favorite on the Mac's signed-in account. |
