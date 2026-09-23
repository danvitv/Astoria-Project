# Astoria Windows developer build

Local builds (without `--dart-define=BUILD_CHANNEL=...`) use the `dev` channel.
The database and media live in `%APPDATA%\Astoria-dev`. A stable Windows build
uses `%APPDATA%\Astoria`. On first start, Astoria imports the Glaze nightly
database and missing media into `Astoria-dev` (stable: `Glaze` -> `Astoria`).
The SQLite backup includes committed WAL data. Existing Astoria files take
precedence, and the Glaze installation is left intact. The database filename
remains `glaze.db` for compatibility with existing code.
To import before launching the application (after `flutter pub get`), run
`dart --packages=.dart_tool/package_config.json scripts/migrate_astoria_windows.dart`
from the project root. The application also performs the import on startup.

Windows SharedPreferences are stored separately, under
`%APPDATA%\Astoria Project\Astoria\shared_preferences.json`. On first start,
missing settings are imported from `%APPDATA%\com.glaze\Glaze` (or the older
`%APPDATA%\com.glaze\glaze_flutter`). Settings already changed in Astoria
take precedence. Old OAuth tokens, sync manifests, and automatic sync state
are not imported: the new cloud namespace requires a fresh connection.
Mobile app data locations are unaffected by this Windows migration.

## Configure cloud sync for a local Windows build

Create `.env` in the project root from `.env.example` (the file is ignored by
Git). Fill in the providers you want to use:

- `DROPBOX_APP_KEY`: App key of a Dropbox app with **App folder** access and
  offline/refresh-token authorization; enable the file read/write permissions
  needed for sync. A separate Dropbox app gives Astoria its own App folder.
- `GDRIVE_CLIENT_ID`: OAuth client ID of a **Desktop app** in your Google Cloud
  project. Enable the Google Drive API and configure the OAuth consent screen
  for the `drive.file` scope; add your account as a test user if the app is in
  testing mode.

Both Windows flows use PKCE and an ephemeral `http://localhost:<port>` callback
through the system browser. A desktop app does not keep an OAuth client secret
confidential; `DROPBOX_APP_SECRET` and `GDRIVE_CLIENT_SECRET` are not needed for
this setup. A new OAuth client requires reconnecting from the sync screen.
Astoria's Google Drive sync root is `Astoria-dev`; Dropbox uses the `dev`
subfolder of the app's App folder. Do not commit `.env` or OAuth tokens.
