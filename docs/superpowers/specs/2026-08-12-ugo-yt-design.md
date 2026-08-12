# ugo-yt — Design

**Date:** 2026-08-12
**Status:** v1 (Android-first)

## Goal

Personal-use app: share a YouTube link from the YouTube app (or anywhere) to **ugo-yt** →
it downloads the full video in the background → watch it in-app with zero ads.
Library keeps at most the **last 10 videos** (oldest evicted automatically).

Personal side-loaded tool only — downloading YouTube videos violates YouTube ToS, so this
is never published to any app store.

## Constraints & decisions

| Decision | Choice | Why |
|---|---|---|
| Framework | **Flutter** (one codebase) | User wants iOS + Android; Android APK now, iOS later. |
| YT extraction | **`youtube_explode_dart`** | Pure Dart (runs on both platforms), actively maintained, handles signature deciphering and throttling workarounds via its `streamsClient`. No Python/yt-dlp binary needed. |
| Quality | Best H.264 video-only ≤1080p + best AAC audio, **muxed on-device with ffmpeg (`-c copy`, no re-encode)**. Fallback: best muxed stream (~360p) if adaptive path fails. | Muxed streams from YouTube top out at ~360p these days; adaptive gets 720p/1080p. Stream-copy mux is fast and battery-cheap. |
| Playback | `video_player` (ExoPlayer) + `chewie` controls | Local MP4 (H.264/AAC) plays natively; no ads by construction. |
| Share intake | Native `ACTION_SEND text/plain` intent-filter in `MainActivity` + MethodChannel (`ugoyt/share`) | ~40 lines of Kotlin, no third-party plugin risk. Handles cold start (pending URL) and warm share (`onNewIntent`). |
| Background download | Downloads run in the main Dart isolate; a tiny native **foreground service** (`dataSync` type, persistent notification) keeps the process alive & unfrozen while the queue is non-empty | Simplest reliable design: sharing always foregrounds ugo-yt anyway; the FGS prevents Android's cached-app freezer from suspending the download when the user switches away. |
| Storage | App-specific external files dir (fallback: internal docs dir); `library.json` index written atomically (tmp + rename) | No storage permissions needed on any Android version. |
| Cap | Max 10 completed videos, evict oldest by download time (files + index entry) | Per requirement. |

## Architecture

```
YouTube app ──share──▶ MainActivity (ACTION_SEND)
                          │ MethodChannel "ugoyt/share"
                          ▼
                    ShareHandler (Dart stream of shared text)
                          ▼
                    parseYoutubeUrl() → videoId
                          ▼
                    DownloadManager (serial queue, main isolate)
                       │  1. start native DownloadService (FGS notification)
                       │  2. youtube_explode: metadata + stream manifest
                       │  3. pick streams (adaptive H.264+AAC, else muxed)
                       │  4. download via streamsClient → .part files (progress)
                       │  5. ffmpeg -c copy mux → <id>.mp4 ; fetch thumbnail
                       │  6. LibraryStore.add() → evict beyond 10
                       │  7. queue empty → stop FGS
                       ▼
                    LibraryStore (library.json + ValueNotifier)
                          ▼
        LibraryScreen (list, progress, retry, delete) ──▶ PlayerScreen (chewie)
```

## Components

- `lib/util/url_parse.dart` — extract a YouTube video ID from arbitrary shared text
  (watch/youtu.be/shorts/live/embed URLs, `si=` junk, surrounding text). Pure function.
- `lib/models/video_item.dart` — id, title, author, durationMs, sizeBytes, status
  (`queued|fetching|downloading|muxing|done|failed`), progress, error, paths, createdAt. JSON round-trip.
- `lib/services/library_store.dart` — loads/saves `library.json`, exposes
  `ValueNotifier<List<VideoItem>>`, `upsert()`, `remove()`, eviction of oldest `done` items beyond 10.
- `lib/services/downloader.dart` — serial queue; extraction, stream selection, download with
  progress, ffmpeg mux, thumbnail, finalization, failure capture; talks to keep-alive service channel.
- `lib/services/share_handler.dart` — MethodChannel wrapper → broadcast stream.
- `lib/ui/library_screen.dart`, `lib/ui/player_screen.dart` — dark theme, red accent.
- `android/.../MainActivity.kt` — share intents, notification-permission request (API 33+), channel.
- `android/.../DownloadService.kt` — start/update/stop foreground `dataSync` service with progress notification.

## Error handling

- Extraction/network/mux failures → item marked `failed` with human-readable error, retry button in UI.
- Duplicate share of an existing `done` video → snackbar "already saved", no re-download; if in-flight → ignored.
- Partial `.part` files cleaned on failure/startup; incomplete (non-`done`) items from a killed
  process surface as `failed (interrupted)` on next launch with retry.
- ffmpeg missing/failing → automatic fallback to best muxed single-file download.

## Testing

- Unit tests (`flutter test`): URL parsing matrix; LibraryStore add/update/evict/persist round-trip
  (temp dir); stream-selection logic on fake manifests.
- Host-side live probe (`dart run tool/probe.dart <url>`): verifies youtube_explode extraction works
  from this machine/network before ever building the APK.
- Release APK built and (if feasible) smoke-tested on an emulator via `adb shell am start -a android.intent.action.SEND ...`.
- Final verification on the user's Pixel (sideload APK).

## v1 scope cuts (explicit)

- iOS: Flutter code is cross-platform, but the iOS **share extension** + background download plumbing
  is a follow-up milestone; not in v1.
- No HTTP range-resume of partial downloads (retry restarts the video).
- Serial download queue (one at a time).
- No quality picker UI (fixed: best ≤1080p H.264).
