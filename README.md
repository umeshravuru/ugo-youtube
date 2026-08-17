# ugo-yt

Personal offline YouTube viewer. Share a video from the YouTube app → **ugo-yt** downloads it
in the background → watch it in-app with zero ads. Keeps your **last 10 videos** (oldest are
evicted automatically, files included).

> ⚠️ Downloading YouTube videos violates YouTube's Terms of Service. This is a personal,
> side-loaded tool — do not publish it to any app store or distribute it.

## How it works

1. In YouTube (or any app), tap **Share → ugo-yt** on a video link.
2. ugo-yt opens, grabs the highest-quality H.264 video (≤1080p) + AAC audio streams,
   downloads them with a progress notification, and merges them into a single MP4 on-device
   (stream copy — fast, no re-encode).
3. **Watch immediately**: while it downloads, tap the item to stream a preview right away
   (~360p over the network); once the download finishes, playback uses the local 1080p file.
4. Videos play in an inline docked player (YouTube-style) with a fullscreen button,
   speed controls, and seek. ugo-yt **remembers where you stopped** and resumes there —
   even across app restarts and the preview→local switch.

You can also paste a link manually with the **⊕ link** button in the app bar.

Fallbacks: VP9/Opus WebM if no H.264 streams exist; YouTube's pre-muxed ~360p stream if
on-device merging fails. Live streams are not supported.

## Tech

- **Flutter** (one codebase, Android + iOS-ready) — Dart 3 / Material 3 dark theme
- [`youtube_explode_dart`](https://pub.dev/packages/youtube_explode_dart) — stream extraction (pure Dart)
- [`ffmpeg_kit_flutter_new_min`](https://pub.dev/packages/ffmpeg_kit_flutter_new_min) — on-device `-c copy` mux
- `video_player` + `chewie` — playback
- Native Kotlin: `ACTION_SEND` share intake (`MainActivity.kt`) and a `dataSync` foreground
  service (`DownloadService.kt`) that keeps the process alive + unfrozen while downloads run

Design doc: [docs/superpowers/specs/2026-08-12-ugo-yt-design.md](docs/superpowers/specs/2026-08-12-ugo-yt-design.md)

## Build

```bash
flutter pub get
flutter build apk --release --split-per-abi
# → build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  (Pixel & modern phones)
```

Useful during development:

```bash
flutter test                                   # unit tests
dart run tool/probe.dart [url] [--download]    # verify extraction works from this machine
```

## Install on your phone (sideload)

1. Copy `app-arm64-v8a-release.apk` to the phone (USB, Drive, etc.), or with USB debugging:
   `adb install app-arm64-v8a-release.apk`
2. Open the APK on the phone → allow **Install unknown apps** for the file manager when asked.
3. First launch asks for notification permission — allow it so you can see download progress.

## Corporate networks (Zscaler etc.)

If downloads fail with `CERTIFICATE_VERIFY_FAILED` you're behind a TLS-inspecting proxy.
Drop the proxy's root CA (PEM) at
`Android/data/com.ugoyt.ugo_yt/files/extra_ca.pem` on the phone and restart the app —
it's trusted **in addition to** system roots, never instead of them.

## Resilience (v1.1)

YouTube's servers routinely stall raw stream transfers mid-download. ugo-yt downloads in
8 MB ranged segments with a per-segment inactivity watchdog, automatic retries, byte-exact
resume, and stream-URL refresh on expiry — stalls recover without restarting the download.
Playback runs under a `mediaPlayback` foreground service with a system **MediaSession**, so
audio keeps playing when you minimize the app or turn the screen off — and the lock screen
shows a media card (artwork, title, progress) with play/pause that controls the player.
Headset/watch media buttons work too.

## Known limitations

- If you force-kill the app mid-download, the item shows **Retry** on next launch
  (resume only works within a session).
- One download at a time (queued serially).
- No audio-focus handling: ugo-yt won't pause other apps' audio and vice versa.
- iOS: the Flutter app runs, but the iOS share extension + background plumbing is a follow-up
  milestone — Android is the testing target for now.
