# Astoria data storage and cloud setup

Local builds (without `--dart-define=BUILD_CHANNEL=...`) use the `dev` channel.
The database and media live in `%APPDATA%\Astoria-dev`. A stable Windows build
uses `%APPDATA%\Astoria`. On first start, Astoria imports the Glaze nightly
database and missing media into `Astoria-dev` (stable: `Glaze` -> `Astoria`).
The SQLite backup includes committed WAL data. Existing Astoria files take
precedence, and the old installation is left intact. The database is
`astoria.db`; an earlier Astoria `glaze.db` is copied into that name on startup
without deleting the earlier file or existing backups.
To import before launching the application (after `flutter pub get`), run
`dart --packages=.dart_tool/package_config.json scripts/migrate_astoria_windows.dart`
from the project root. The application also performs the import on startup.

Windows SharedPreferences are stored separately, under
`%APPDATA%\Astoria Project\Astoria\shared_preferences.json`. On first start,
missing settings are imported from `%APPDATA%\com.glaze\Glaze` (or the older
`%APPDATA%\com.glaze\glaze_flutter`). Settings already changed in Astoria
take precedence. Old OAuth tokens, sync manifests, and automatic sync state
are not imported: the new cloud namespace requires a fresh connection.
Android/iOS now keep the database and media in the Astoria sandbox's
`Documents/Astoria`; macOS and Linux use Astoria-named application data
folders. They also import an accessible legacy `Glaze/glaze.db` and missing
media from the previous location. The changed mobile application IDs separate
Astoria from the older Glaze app: Android/iOS sandbox isolation prevents an
automatic cross-app transfer; use an exported backup for that case. A changed
macOS bundle ID may also separate OS-managed preferences: import a backup if
the earlier app's settings are not accessible. Mobile SharedPreferences stay
in the OS-owned preferences of the Astoria app ID, not inside
`Documents/Astoria`.

## Configure cloud sync (Windows, Android, iOS)

Create `.env` in the project root from `.env.example` (the file is ignored by
Git). Fill in the providers you want to use:

- `DROPBOX_APP_KEY`: App key of a Dropbox app with **App folder** access and
  offline/refresh-token authorization. In its App Console, register the exact
  `http://localhost:43178` (desktop). Mobile uses Dropbox's own SDK-style
  callback `db-<APP_KEY>://2/token` (register it in the App Console if the
  console permits custom redirects); enable **Allow public clients** (PKCE),
  and grant `files.content.read`, `files.content.write`, `files.metadata.read`,
  and `account_info.read`. A separate Dropbox app gives Astoria its own App
  folder. If another process is using port 43178, close it before connecting.
- Enable the Google Drive API; configure Google Auth Platform consent with
  `drive.file`, and add your account as test user if the app is in Testing.
- `GDRIVE_CLIENT_ID`: OAuth client ID of a **Desktop app** for Windows (also
  used by the desktop loopback flow on Linux). No manually registered Google
  localhost redirect is required for a Desktop client.
- `GDRIVE_ANDROID_SERVER_CLIENT_ID`: a **Web application** OAuth client ID
  used as `serverClientId` by Google Sign-In for Android. Create **Android**
  OAuth clients in the same project for each installed package and signing
  certificate SHA-1: `app.astoria.flutter.dev` for local dev,
  `app.astoria.flutter` for stable (also `.staging` if built). Register both
  the debug SHA-1 (`keytool -list -v -alias androiddebugkey -keystore
  ~/.android/debug.keystore`, default password `android`) and the release
  signing SHA-1 as separate clients when those certificates differ.
- `GDRIVE_IOS_CLIENT_ID`: an **iOS** OAuth client ID for the actual bundle ID:
  `com.danvitv.astoria.dev` for local dev. For stable use a separate client
  registered for `com.danvitv.astoria` (and another for `.staging` if built).
  Each distinct bundle ID needs its own iOS client ID in its build's `.env`.
  Run `bash ios/Runner/generate_env_xcconfig.sh`
  **before** `flutter build ios` or opening Xcode; it generates the Dropbox and
  reversed Google URL schemes in the ignored local
  `ios/Runner/Configs/Env.xcconfig` from `.env`.

Windows uses PKCE through the system browser. Dropbox listens on registered
port 43178; Google uses an ephemeral localhost port. On Android/iOS Google
uses the platform sign-in SDK, then authorizes `drive.file` on Connect; the SDK
restores authorization at startup without requesting fresh consent. Dropbox
uses the system browser with PKCE and an app-key-specific callback scheme.
Client secrets cannot be kept confidential in a shipped app;
`DROPBOX_APP_SECRET` and `GDRIVE_CLIENT_SECRET` are not needed.
A new OAuth client requires reconnecting from the sync screen.
Astoria's Google Drive sync root is `Astoria-dev`; Dropbox uses the `dev`
subfolder of the app's App folder. Do not commit `.env` or OAuth tokens.

For CI, set the corresponding GitHub Actions secrets `DROPBOX_APP_KEY`,
`DROPBOX_APP_KEY_DEV` if dev has a separate Dropbox app,
`GDRIVE_CLIENT_ID`, `GDRIVE_ANDROID_SERVER_CLIENT_ID`, and
`GDRIVE_IOS_CLIENT_ID` for dev; before building release iOS also set
`GDRIVE_IOS_CLIENT_ID_RELEASE` for `com.danvitv.astoria` (optional staging and
nightly IDs are in `docs/RELEASE_CHANNELS.md`). Mobile package/bundle IDs and
signing SHA-1 must match the credentials used for **that build channel**. A build
with no credentials can run, but those providers cannot be connected. On
Windows we cannot verify an iOS build or actual mobile OAuth without a
Mac/device and these credentials.
