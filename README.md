# K100 — Offline AI Language Speaking Tutor

A complete, production-ready Android app that holds a spoken conversation with you in the
language you are learning. The language model, the speech recognition and the speech
synthesis all run **on the device**. There is no API key, no account, no server, no
subscription and no per-token billing — the only network request the app ever makes is the
one-time download of the model weights that *you* start.

```
┌────────────┐   ┌──────────────────────┐   ┌────────────┐
│  You speak  │──►│  speech_to_text      │──►│  one GGUF  │
└────────────┘   │  (on-device engine)  │   │  inference │
      ▲          └──────────────────────┘   └─────┬──────┘
      │                                           │  strict JSON
      │          ┌──────────────────────┐         │  reply / translation /
      └──────────│  flutter_tts         │◄────────┘  correction / score
   microphone    │  speaks ONLY the     │
   re-armed +300 ms  reply_target_language
   after completion  │
                 └──────────────────────┘
```

---

## Features

| | |
|---|---|
| **On-device LLM** | llama.cpp (via `fcllama`) running a quantised GGUF SLM. Default `Qwen2.5-1.5B-Instruct-Q4_K_M`, alternative `Gemma-2-2B-It-Q4_K_M`, plus 0.5B and 3B options. |
| **On-device STT** | `speech_to_text` — prefers the offline recogniser, falls back once to the platform one and tells you which ran. |
| **On-device TTS** | `flutter_tts` with the installed system voices, a voice picker and a per-level speaking rate. |
| **Single-inference dual output** | One completion returns `reply_target_language`, `reply_translation`, `grammar_correction`, `explanation`, `fluency_score` (plus optional `reply_romanization`, `key_phrase`, `key_phrase_translation`). The TTS speaks **only** the target-language field; the UI renders an expandable *Grammar & Feedback* card under your bubble. |
| **Anti-loop half-duplex pipeline** | `idle → userListening → aiThinking → aiSpeaking → idle`. The microphone is physically locked while the tutor thinks or speaks and is released exactly 300 ms after the TTS completion callback. |
| **Onboarding** | Native language + target language + Beginner / Intermediate / Advanced, then the model downloader. |
| **Free talk & role-play** | Free conversation plus nine scenarios (café, airport, hotel, doctor, job interview, market, small talk, directions) and six guided course stages (A1→C1). |
| **Vocabulary bank** | `key_phrase` is mined from every reply and reviewed with a Leitner schedule. |
| **History** | Every session and transcript in local SQLite, with per-turn feedback. |
| **No bundled weights** | The APK ships **without** `.gguf` files. A Gradle task fails the build if anyone tries. |

---

## Requirements

* Android **8.0 (API 26)** or newer, **arm64-v8a** (64-bit ARM). No 32-bit or x86 build is
  produced — the quantised engine is compiled for arm64 only.
* ~1.5 GB of free storage for the recommended 1.5B model (0.5 GB for the smallest).
* 4 GB of RAM recommended for 1.5B; 6 GB for the 3B options.
* A text-to-speech voice for the target language (Android ships with English; others come
  from *Settings → System → Languages & input → Text-to-speech*, or the vendor's store).

> **Expected speed.** `fcllama` builds llama.cpp without a GPU backend, so a 1.5B Q4_K_M
> model decodes at roughly **5–15 tokens/second** on a mid-range phone. That is a
> deliberate trade: no vendor-specific NNAPI/HTP dependencies, and it works on every arm64
> device. The 0.5B model is roughly three times faster; the 3B models are noticeably slower.

---

## Install

Download **[`app-arm64-v8a-release.apk`](https://github.com/smfahadelahi/K100/releases/download/v1.0.0/app-arm64-v8a-release.apk)**
(~21 MB) from the [latest release](https://github.com/smfahadelahi/K100/releases/latest) and
open it on the phone. Android will ask you to allow installing from this source; that prompt
is normal for any app that is not distributed through the Play Store.

Then:

1. Pick your native language, your target language and your level.
2. Choose a model and tap **Download** (~1.1 GB for the default). The download is
   resumable, pause-able and SHA-256 verified against the Hub's LFS metadata.
3. Once it says *Ready*, tap the orb and start talking.

The APK is arm64-v8a only, so it installs on any 64-bit ARM phone running Android 8.0 or
newer and on nothing else. It contains the whole app and the llama.cpp engine, but no model
weights — those are downloaded once, from Hugging Face, into the app's own documents
directory, and are never uploaded anywhere.

### Signing

Release APKs are signed with **your** key when these four repository secrets exist:

| Secret | Contents |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | the store password |
| `ANDROID_KEY_ALIAS` | the key alias |
| `ANDROID_KEY_PASSWORD` | the key password |

Without them the workflow generates a throwaway keystore so the build still produces an
installable APK (the release notes then say `Signing: ci-temporary`). That is what the
current `v1.0.0` asset is: **installable, but not upgradeable in place across rebuilds** —
Android refuses to update an app whose signature changed, so a later throwaway-signed build
needs an uninstall first. Add the four secrets before you rely on in-place updates.

You can verify any downloaded APK against the SHA-256 printed in its release notes:

```bash
sha256sum app-arm64-v8a-release.apk
```

---

## Build it yourself

```bash
git clone https://github.com/smfahadelahi/K100.git
cd K100

flutter pub get
flutter build apk --release --split-per-abi        # needs the Flutter 3.35.7 toolchain
# -> build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

The Android toolchain is pinned and documented in `android/`:

| Component | Version | Why |
|---|---|---|
| Flutter | **3.35.7** | Newest patch of the line whose supported window still contains the `fcllama` plugin's AGP/Kotlin versions. |
| Gradle | **8.14.3** | Flutter 3.35+ requires ≥ 8.14.0; AGP 8.11.1 is not certified for Gradle 9.x. |
| AGP | **8.11.1** | Flutter 3.35+ requires ≥ 8.11.1. |
| Kotlin | **2.2.20** | Flutter 3.35+ requires ≥ 2.2.20. |
| Java | **17** | Required by AGP 8.11. |
| compileSdk / targetSdk | **36** | Must be ≥ every plugin's `compileSdk` (fcllama asks for 35) or Flutter's dependency check errors. |
| minSdk | **26** | Android 8.0 — the floor for the adaptive icon and the recogniser behaviour this app relies on. |
| NDK | **28.2.13676358** | The NDK Flutter pins; ≥ fcllama's 28.0.x. |

`android/gradle.properties` sets `skipDependencyChecks=true` because the `fcllama` plugin
module declares older AGP/Kotlin versions than Flutter 3.35 validates. The *app* module is
inside the supported window; without that flag the build fails on the plugin's metadata, not
on anything in this project. The equivalent CLI switch is
`flutter build apk --android-skip-build-dependency-validation`.

R8/ProGuard is **off** by default. The engine is reached through a bound Android service and
the speech plugins resolve classes reflectively; a silently mis-shrunk release APK crashes
on launch. `android/app/proguard-rules.pro` already contains the keep rules, so flipping
`minifyEnabled`/`shrinkResources` to `true` after a device test is a one-line change.

### CI

`.github/workflows/build-release-apk.yml` runs on every push to `main` and on
`workflow_dispatch`. It sets up Java 17 (Temurin), the Android SDK + NDK + CMake, caches
Gradle and pub, analyses, tests, and builds `--split-per-abi --release`, then uploads
`app-arm64-v8a-release.apk` and attaches it to a GitHub Release.

**It never fails for want of secrets.** If the four signing secrets below are absent, the
workflow generates a throwaway keystore and signs the release build with it, so a fresh fork
still produces an installable APK:

| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Key alias |
| `ANDROID_KEY_PASSWORD` | Key password |

The workflow also refuses to publish an APK that bundles model weights, contains any ABI
other than `arm64-v8a`, or exceeds 120 MB.

---

## How the anti-loop works

This is the part that matters. A voice tutor that keeps its microphone open while its own
text-to-speech plays hears itself, answers itself, and loops forever. K100 makes that
impossible three times over:

1. **An auditable transition table** (`kAllowedTransitions` in `lib/models/tutor_state.dart`).
   There is no `userListening → aiSpeaking` edge: speech can only start from `aiThinking`,
   which is only reachable once the recogniser has been stopped. There is no
   `aiSpeaking → userListening` edge either — the mic can only be re-armed through `idle`.
2. **A single lock flag** (`TutorRuntimeState.micLocked`). It is raised *before inference
   starts* — stricter than "before TTS", because a burst of noise during generation would
   otherwise become a second turn — and lowered only by `_unlockMicrophone`, which waits
   `AppConfig.postTtsMicUnlockDelay` (**300 ms**) after `flutter_tts` fires its completion
   handler. 300 ms covers the audio still sitting in Android's output buffer plus the
   recogniser's own reset.
3. **A turn token** (`_turnToken`). Every asynchronous continuation captures the token it
   started with and returns early if the token moved on. Interrupting, leaving the screen, or
   a late recogniser callback cannot resurrect a dead turn.

Any illegal transition is an `assert` in debug builds and a logged, forced recovery in
release — a stuck microphone on a learner's phone is worse than a transition that should not
have happened. `test/tutor_state_test.dart` pins the two forbidden edges as executable tests.

---

## Project layout

```
lib/
  core/            constants (every tunable), logger, theme
  models/          language, learner profile, scenario, chat message,
                   ai_response (the strict-JSON parser), model catalogue, tutor state
  services/        llm_service (HF downloader + llama.cpp wrapper)
                   stt_service, tts_service, prompt_builder
                   database_service (SQLite), profile_repository (SharedPreferences)
                   voice_pipeline_controller (the STT→LLM→TTS state machine)
  providers/       the Riverpod graph
  ui/screens/      setup, home, chat_tutor, history, vocabulary, settings
  ui/widgets/      voice_orb, chat_bubble, grammar_feedback_card, pipeline_status_bar,
                   model_card, speaker_button
test/              parser and state-machine tests
android/           pinned Gradle/AGP/Kotlin/NDK toolchain, manifest, icons, ProGuard rules
.github/workflows/ signed release APK pipeline
```

### The response contract

The model is instructed to answer with exactly one JSON object:

```json
{
  "reply_target_language": "…",   // spoken by TTS, shown as the tutor's bubble
  "reply_translation": "…",       // native-language line under it
  "grammar_correction": "…",      // corrected learner sentence, or null
  "explanation": "…",             // one line on why, or null
  "fluency_score": 72             // 0–100
}
```

A 1.5B model *will* eventually emit a stray comma, so `AiResponse.parse` never throws and
never returns null. It walks four stages — strict `jsonDecode` → mechanical repair (smart
quotes, single quotes, trailing commas, unterminated tail) → regex field recovery → plain
text — and records which one it used in `AiParseMode`, surfaced in the UI as a small
*repaired* badge. If a reply is unusable the pipeline re-asks **once** with a stricter
reminder and a pre-filled object at `temperature: 0.15` before giving up and apologising in
the transcript.

---

## Privacy

* No accounts, no analytics, no telemetry, no crash reporting service.
* Conversations, grammar feedback, vocabulary and stats live in a local SQLite database
  inside the app (`k100_tutor.db`) and are excluded from cloud backup and device transfer.
* The only outbound traffic is the HTTPS GET of the model file from `huggingface.co`, which
  you start yourself. Nothing is uploaded — not your audio, not your transcripts, not a
  device identifier.
* Nothing needs a network connection after the model is on disk, including speech
  recognition when a language pack is installed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| "No *X* recogniser on this device" | Install the offline language pack: *Settings → System → Languages & input → Voice input*. Without it the app falls back to the platform recogniser, which needs a network. |
| TTS says nothing | No voice installed for the target language. Android ships English only; install others in *Text-to-speech settings*. The reply is still shown as text. |
| "Not enough memory to load this model" | Pick Qwen2.5-0.5B, or close other apps. `largeHeap` is enabled, but a 1.5B model needs ~1 GB free. |
| Build fails on plugin AGP/Kotlin versions | `skipDependencyChecks=true` is already set in `android/gradle.properties`; if you removed it, re-add it or pass `--android-skip-build-dependency-validation`. |
| App installs but the engine crashes on load | Native libraries were stripped. Check `keepDebugSymbols` in `android/app/build.gradle`; a stripped llama.cpp `.so` aborts on load. |
| Turns feel slow | That is the honest cost of on-device inference: ~5–15 tok/s for 1.5B. The status bar shows the real latency and tok/s. |

---

## Licence and third-party components

The app source is yours to use. The model weights are **not** included and carry their own
licences — check each model card before redistributing (`Qwen2.5` is Apache-2.0,
`Gemma` has its own terms). llama.cpp is MIT-licensed and compiled from source by the
`fcllama` plugin.
