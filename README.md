# Broadcast My Radio

Android-only radio studio app: mic broadcast + audio player over Icecast/Shoutcast (Zeno.fm compatible).
Package ID: `ng.soccerhub.bcast`

Hybrid architecture:
- **Flutter** — UI shell (Studio, Cart Wall, Playlist, Library, Settings)
- **Native Kotlin** — audio engine (mic capture, mixer, encoder, Icecast source connection), running as a foreground service so it survives backgrounding/screen-off without the OS killing it.

## Status: core audio pipeline wired, unverified

The full mic → mixer → encoder → Icecast pipeline is written and connected end-to-end (mic-only, no track/cart mixing sources yet). No local Flutter SDK in this environment, so **none of this has been compiled or run** — first real test needs to happen via GitHub Actions CI or a local Android Studio/Flutter setup, same pattern as StoryVoice.

## What's in place

- `pubspec.yaml` — Flutter deps (riverpod, permission_handler, file_picker, shared_preferences, audiotags)
- `lib/main.dart` — app entry point
- `lib/screens/studio_screen.dart` — first real screen: mic toggle, live/stop, level meters, crossfader
- `lib/services/broadcast_engine.dart` — the full platform channel contract (Dart side) between Flutter and native
- `lib/services/settings_service.dart` — persists Icecast server config (maps to Zeno.fm Broadcast Settings fields)
- `android/app/src/main/AndroidManifest.xml` — mic, foreground service, wake lock, notification permissions
- `android/.../audio/AudioCaptureManager.kt` — `AudioRecord`-based mic capture on a dedicated high-priority thread, mono 44.1kHz PCM16, with gain/mute and RMS level metering
- `android/.../audio/AudioMixer.kt` — combines mic PCM with track/cart PCM (via a lock-free ring buffer so track decode stalls never block the mic thread), independent gain per source, ducking-style crossfade
- `android/.../audio/StreamEncoder.kt` — `MediaCodec` AAC-LC encoder with ADTS framing, no external native deps
- `android/.../audio/IcecastSourceClient.kt` — raw-socket Icecast2 SOURCE protocol implementation (Basic auth, correct leading-slash mount handling, exponential-backoff reconnect, separate metadata update path)
- `android/.../BroadcastService.kt` — foreground service orchestrating the full pipeline; exposes a `LocalBinder` for fine-grained control (gain, mute, crossfade, metadata) beyond simple start/stop
- `android/.../MainActivity.kt` — binds to the service, wires every Dart method call through to it, forwards all pipeline callbacks (status/levels/stats/errors) back to Flutter via the event channels

## What's NOT built yet (next steps, in rough order)

1. **Local Flutter project init** — run `flutter create .` in this directory (or equivalent) to generate the full Android scaffolding this hand-written tree is layered on top of (Gradle wrapper files, `local.properties`, launcher icons, etc.).
2. **First real build + on-device test** — mic-only live streaming to your Zeno.fm mount point, to confirm the pipeline actually works before adding more surface area. This is the critical next milestone — everything below assumes it passes.
3. **TrackPlayer / CartPlayer** — decode local audio files (playlist bed + cart wall sounds) to PCM and feed into `AudioMixer.pushTrackSamples()`. Needed before Cart Wall / Playlist screens are anything more than UI shells. Track-side level metering (currently hardcoded to 0 in `BroadcastService`) depends on this too.
4. **Cart Wall, Playlist, Library, Settings screens** — UI only exists for Studio so far.
5. **Release signing config** — currently defaults to debug signing in `build.gradle`; needs a real keystore wired via GitHub Actions secrets (same pattern as StoryVoice's CI).
6. **MP3 encoder option** — deferred v1 decision: AAC uses Android's built-in `MediaCodec` (zero extra native deps); MP3 would need a bundled LAME/shine `.so` via JNI, a meaningfully bigger CI/build lift. Add later behind the same `StreamEncoder` interface if needed.
7. **HLS (.m3u8) stream playback** — `UrlStreamPlayer`/`FileDecoder` currently only support direct MP3/AAC HTTP(S) stream URLs. HLS is a playlist format (segments + manifest) that `MediaExtractor` can't parse directly — would need ExoPlayer or similar for segment-stitching. Explicitly out of scope for now; `UrlStreamPlayer.play()` rejects `.m3u8` URLs with a clear error rather than silently failing.
8. **Voice effects, Equalizer (EQ), Compressor/Limiter** — genuine DSP algorithms, not built-in Android effects like echo cancellation/noise suppression/auto gain (which ARE implemented, see below). These need real signal processing code written from scratch. Prioritized as the next dedicated batch of work.
9. **Multi-microphone / external USB / Bluetooth mic support** — real but fiddly (device enumeration, hot-swap handling, `AudioDeviceInfo` routing). Not started; would need its own scoped session.
10. **Headphone/cue monitoring** — would need a second audio output path (`AudioTrack` routed specifically to headphones) separate from the main mixed stream. Not started.
11. **True mid-track pause/resume** — see TrackPlayer's docs; pause currently restarts from the beginning rather than resuming position, since the decode pipeline doesn't expose seek.

## Broadcasting section — status

Built and wired: Go Live/Stop, ON AIR indicator, mic mute + push-to-talk, gain control (mic + track), crossfade, mixer (mic+track+cart+playlist+URL stream), echo cancellation, noise suppression, auto gain (all three via Android's built-in `AudioEffect` APIs, gracefully degrading per-device based on real hardware support), emergency stop, broadcast timer, dead-air detection (independent of Auto DJ), broadcast history (local, persisted).

Deliberately not built yet (see items 8-11 above): voice effects, EQ, compressor/limiter, multi-mic/USB/Bluetooth routing, headphone cue monitoring, true pause/resume.

## Known gaps / things to sanity-check on first real device test

- `StreamEncoder`'s ADTS header assumes AAC-LC + the sample rate table is standard MPEG-4 — worth confirming Zeno.fm's player actually parses the resulting stream correctly, since this hasn't been tested against a live server yet.
- `IcecastSourceClient` reconnect logic gives up after 5 attempts with exponential backoff (2s→32s) — reasonable default, but untested against real network drop scenarios (e.g. switching from WiFi to mobile data mid-stream).
- Foreground service `START_STICKY` restart on system kill does **not** currently resume a live stream automatically — the service would restart but stay idle until Flutter calls `startStream()` again. Acceptable gap for v1, worth revisiting if backgrounding proves unreliable in practice.

## Building & releasing (Termux → GitHub Releases, no local build)

Termux is used only to push code — the actual build happens in GitHub Actions,
same pattern as StoryVoice/SoccerHub. The key difference from a typical setup:
**the workflow uploads the APK directly to a GitHub Release, not to Actions'
artifact storage** — artifact storage is capped and expires after 90 days,
which is what caused the earlier storage issues on other projects. Release
assets are unlimited and permanent.

### One-time setup (GitHub repo)

1. Create the repo on GitHub, push this project to it.
2. Generate a release keystore if you don't have one yet:
   ```
   keytool -genkey -v -keystore broadcast_my_radio.keystore \
     -alias broadcast_my_radio -keyalg RSA -keysize 2048 -validity 10000
   ```
3. Base64-encode it and add these as repo secrets (Settings → Secrets and
   variables → Actions → New repository secret):
   - `ANDROID_KEYSTORE_BASE64` — output of `base64 -w0 broadcast_my_radio.keystore`
   - `KEYSTORE_PASSWORD` — the keystore password you set above
   - `KEY_ALIAS` — `broadcast_my_radio` (or whatever alias you used)
   - `KEY_PASSWORD` — the key password you set above

**Keep the keystore file itself somewhere safe outside the repo** (e.g. a
password manager or encrypted backup) — if you lose it, you can never publish
an update to an app already installed from a build signed with it.

### Day-to-day workflow from Termux

```bash
# Termux: clone once
pkg install git
git clone https://github.com/<you>/broadcast_my_radio.git
cd broadcast_my_radio

# ... edit files (or pull in files generated elsewhere) ...

git add .
git commit -m "describe the change"
git push origin main
```

Pushing to `main` triggers the workflow automatically and it'll build + publish
a pre-release build. To choose APK vs AAB, or set a custom release tag, trigger
it manually instead: GitHub repo → Actions → "Build Android App" → Run workflow.

The resulting APK shows up under the repo's **Releases** tab, tagged
`build-<run number>-<short commit sha>` unless you specified a custom tag.
Download it there, or share the release link directly.

## Zeno.fm / Icecast reference (for your own account)

- Server type: standard Icecast2 (Zeno confirmed via their own BUTT/Edcast setup docs)
- Format: MP3 or AAC supported; MP3 @ 128kbps is the current default
- Mount point **must** be sent with a leading `/`
- Bitrate cap depends on plan (Starter: 192kbps, Prime: 320kbps) — 128kbps is safely within either

## Podcast Studio (v0.2)

BroadcastNG now includes a native post-mixer podcast recorder. It supports standalone podcast recording and recording a live show at the same time. The recorder captures the exact mixed PCM output that is sent to the live encoder, so the saved episode includes mic, playlist beds and cart audio.

### Included
- Standalone podcast recording while not live
- One-tap Live + Podcast recording
- Background-safe Android foreground recording
- Master WAV capture with 16-bit PCM
- Episode library and draft metadata
- Show name, host, category, episode type, season/episode number and explicit flag
- Artwork selection
- Chapter markers
- Production notes
- Episode status workflow (draft / ready to publish)
- Podcast RSS feed generator scaffold

### Distribution note
Podcast directories such as Apple Podcasts and Spotify generally ingest episodes from a hosted RSS feed rather than accepting an arbitrary in-app episode upload. The app therefore keeps recording/publishing metadata separate from directory distribution. A production hosting endpoint can be connected later without changing the audio recording engine.

## Podcast Publishing Hub (v0.3)

The Podcast Studio now includes a publishing/distribution layer designed around a hosted RSS feed.

### Mobile app
- Configurable HTTPS podcast publishing API + bearer token
- Upload episode audio and artwork as multipart form data
- Publish now through the backend
- Optional automatic upload/publish immediately after a recording finishes
- RSS base URL, website, language and copyright settings
- Episode metadata for season, episode number and keywords
- Distribution status per episode
- Remote episode/RSS identifiers
- Hosted analytics with local fallback counters
- Podcast Publishing Hub UI from the Podcast Studio and Episode Editor
- RSS export upgraded with iTunes metadata, GUIDs, enclosures, authors, explicit flags and chapter markers

### Backend contract
See `podcast_backend_contract.md`. The backend owns audio hosting, transcoding, RSS hosting, scheduled publication and provider-specific directory credentials. This keeps sensitive Apple/Spotify/Amazon credentials out of the Android app.

### Important production note
The app cannot create an Apple Podcasts or Spotify account on behalf of the broadcaster. Those platforms require account ownership/verification and directory submission or hosting authorization. Once the show is established, the publishing backend can keep the RSS feed updated automatically; provider-specific API credentials, where supported, belong on the backend.

## v0.4 Professional Studio
- Professional mixer controls with persisted channel presets.
- Auto DJ controls for shuffle, repeat protection, artist/category rotation and crossfade.
- Station ad library with automatic insertion policy settings.
- Multiple podcast shows and hosts stored locally.
- Podcast production controls for noise-reduction strength, intro/outro assets, ad assets and non-destructive edit markers (trim, silence removal, fade, marker).
- Existing native noise suppression remains available for live/recorded microphone capture.

Production note: the editor stores non-destructive edit instructions and automation assets. A final offline render/export pipeline still needs to be connected to the publishing backend/native media processor for destructive audio rendering.

## Build troubleshooting

The Professional Studio v0.4 source includes the podcast edit-operation model and uses `Future<File>` for RSS export, matching `PodcastService.generateRssFeed()`. The Ads and Shows/Hosts views are complete Dart widget expressions.
