<p align="center">
  <img src="assets/logos/astoria-sticker.png" width="320" alt="Astoria black cat logo with amber eyes">
</p>

<h1 align="center">Astoria</h1>

<p align="center">
  A local-first, cross-platform AI roleplay client built with Flutter.
</p>

<p align="center">
  <a href="README.ru.md">Русский</a> ·
  <a href="LICENSE">AGPL-3.0</a> ·
  <a href="docs/ARCHITECTURE.md">Architecture</a>
</p>

> [!WARNING]
> Astoria is an **early development preview**. Data formats, features and UI may
> change, and bugs may cause data loss. Keep backups of anything important.

## Current status

Astoria is usable as a development build, but it is not a finished or
device-certified release. The current focus is Windows and Android; iOS, macOS
and Linux targets are present but receive less runtime validation. Web is not a
supported target.

There are currently **no official public binaries**. Build from source using the
instructions below. Release artifacts will eventually be published in
[Astoria-Project-Release](https://github.com/danvitv/Astoria-Project-Release/releases).

## What works today

- **Roleplay chat** — streaming generation, regeneration, swipe alternatives,
  editing, branching, background generation and reasoning-content handling.
- **Characters and prompts** — SillyTavern V2 character cards, presets,
  lorebooks, personas, author's notes, regex scripts and a broad macro set.
- **Long-session context** — Memory Books, summaries, Links and Studio Ledger
  help retain relevant facts and scene state. Review flows remain explicit where
  generated memory can change durable data.
- **Astoria Studio** — configurable multi-stage generation with specialist
  agents, controllers, final writers, canon state and reconciliation tooling.
- **Astoria Assistant** — an integrated support workspace with its own model
  connection, bounded diagnostics, source navigation, selected app actions and
  encrypted support-report export. It is useful now, but its original product
  plan and credential migration are not complete.
- **Extensions (ExtBlocks)** — post-generation info blocks, image generation,
  sandboxed JavaScript and interactive HTML panels with deny-by-default
  capabilities.
- **Image generation** — provider-backed image generation inside chat and
  extension workflows.
- **Themes and layouts** — light/dark themes, custom colors, fonts and
  backgrounds, with desktop and mobile layouts.
- **Local statistics and storage** — chats, characters, presets and related app
  data are stored in a local SQLite database.
- **Optional sync** — Dropbox and Google Drive integrations can move backups
  between devices.

Compatibility is practical rather than absolute. Astoria imports and exports
SillyTavern V2 cards and supports common presets, lorebooks, regex scripts and
macros, but it is not a drop-in implementation of every SillyTavern feature.

## Privacy and safety

Astoria is local-first, not offline-only. Your database and media remain on your
device unless you use sync or export features, but prompts and selected context
are sent to the model provider you configure. Image providers likewise receive
their generation inputs.

Astoria Assistant can read application data only after its single app-data
consent is enabled. Credential material is excluded from its source readers, and
support-report export has a separate preview and approval flow. The assistant's
legacy credential cleanup is still unfinished, so do not treat this preview as a
security-audited product.

Imported presets and extensions may contain regexes, scripts or interactive
content. Review material from sources you do not trust before enabling it.

## Build from source

### Requirements

- Flutter 3.44+ with Dart 3.12+
- Git
- The native toolchain for your target platform:
  - Visual Studio with the C++ desktop workload for Windows
  - Android Studio / Android SDK for Android
  - Xcode for iOS and macOS
  - Flutter's Linux desktop dependencies for Linux

### Setup

```bash
git clone https://github.com/danvitv/Astoria-Project.git
cd Astoria-Project
flutter pub get
cp .env.example .env
flutter run -d windows # or android, ios, macos, linux
```

The `.env` file is included in the Flutter asset bundle and must exist. Empty
values are valid; Dropbox and Google Drive sign-in will simply remain
unavailable. Never commit your populated `.env` file.

### Checks and builds

```bash
flutter analyze
flutter test
flutter build windows
```

For an ARM64 Android release build on Windows:

```powershell
.\scripts\build_android_arm64.ps1
```

After changing Drift, Freezed or JSON-serializable models, regenerate code:

```bash
dart run build_runner build
```

See [the project workflow](docs/WORKFLOW.md),
[build notes](docs/BUILD_NOTES.md) and
[release channels](docs/RELEASE_CHANNELS.md) for platform-specific details.

## Technology

Astoria uses Flutter, Riverpod, Drift/SQLite, Dio, GoRouter and a WebView-based
chat renderer. The main source areas are:

```text
lib/core/                 models, database, providers and shared services
lib/features/chat/        chat UI, generation and WebView bridge
lib/features/studio/      multi-stage Studio workflows
lib/features/memory/      Memory Books and consolidation flows
lib/features/extensions/  ExtBlocks and sandbox bridge
lib/features/image_gen/   image generation providers and UI
lib/features/cloud_sync/  Dropbox and Google Drive integration
lib/features/support_assistant/  Astoria Assistant
assets/chat_webview/      message renderer and bridge assets
docs/                     architecture, invariants and development notes
test/                     unit, widget, integration and regression tests
```

Start with [Architecture](docs/ARCHITECTURE.md) and
[Invariants](docs/INVARIANTS.md) before changing storage, generation or extension
security boundaries.

## Credits

- [SillyImages](https://github.com/0xl0cal/sillyimages) — reference for inline
  image-generation providers.
- [SillyTavern-CharacterLibrary](https://github.com/Sillyanonymous/SillyTavern-CharacterLibrary)
  — reference for browser-based JanitorAI extraction.
- [Marinara Engine](https://github.com/Pasta-Devs/Marinara-Engine) and
  [Lumiverse](https://github.com/prolix-oc/Lumiverse) — inspiration for agentic
  generation workflows.

### Testers

The people who find the bugs before the release does — Astoria's Hall of Fame:

**nightsyr** *(honorary tester)*, Саша Белый, múrx, lina, ShikiN, N K,
Сатаник1155.

## License

Astoria is licensed under the [GNU Affero General Public License v3.0](LICENSE).
Third-party components and assets remain subject to their respective licenses.
