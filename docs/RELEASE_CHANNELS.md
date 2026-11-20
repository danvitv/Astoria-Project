# Astoria build channels

The public source repository uses `master` as its default stable branch and
`dev` for ongoing development. Both manual build workflows derive
`BUILD_CHANNEL` from the selected branch and pass it to Flutter and the native
Android/iOS build steps:

| Branch | Channel | Android applicationId | iOS bundle ID | Windows data folder | Drive root |
|---|---|---|---|---|---|
| `master` | `stable` | `app.astoria.flutter` | `com.danvitv.astoria` | `Astoria` | `Astoria` |
| `dev` | `dev` | `app.astoria.flutter.dev` | `com.danvitv.astoria.dev` | `Astoria-dev` | `Astoria-dev` |
| feature / other working branch | `dev` | `app.astoria.flutter.dev` | `com.danvitv.astoria.dev` | `Astoria-dev` | `Astoria-dev` |

A local Flutter build without `--dart-define=BUILD_CHANNEL=...` defaults to
`dev`; Android Gradle and iOS `Channel.xcconfig` default to `dev` as well.
On all desktop platforms the local data folder is `Astoria` or
`Astoria-<channel>` (Windows `%APPDATA%`, Linux XDG data home, macOS Application
Support). Android/iOS use a per-app sandbox with `Documents/Astoria`. The
database is `astoria.db` on every platform; existing `glaze.db` and media are
copied before startup without removing the original. OS preferences are scoped
to the Astoria app identity; see `docs/ASTORIA_WINDOWS_DEV.md`.

Developer mode is opt-in on every channel: unlock it by tapping the About
version badge seven times. The build watermark stays visible on all `0.x`
builds (including stable), unless a user chooses to hide it. These values are
stored in SharedPreferences; the channel only supplies defaults.

## Cloud isolation and credentials

Google Drive uses the channel-specific `Astoria` root shown above. Dropbox
uses an App-folder-relative `/dev` subtree on working builds; stable uses the
App-folder root. Separate Dropbox app keys are optional; a stable wipe must
not delete existing dev, staging or nightly subfolders. See
`lib/features/cloud_sync/services/dropbox/dropbox_adapter.dart`.

Desktop Google auth uses `GDRIVE_CLIENT_ID` (OAuth **Desktop app**).
Android Google Sign-In uses `GDRIVE_ANDROID_SERVER_CLIENT_ID` (OAuth **Web
application**) plus a Google Android OAuth registration for each native
package ID and signing SHA-1. iOS uses an OAuth **iOS** client whose registered
bundle ID must match the build:

| Channel | Actions secret for iOS OAuth client ID |
|---|---|
| `dev` | `GDRIVE_IOS_CLIENT_ID` (existing dev secret) |
| `stable` (`master`) | `GDRIVE_IOS_CLIENT_ID_RELEASE` (create before building) |

The iOS jobs of both manual workflows select the corresponding secret and
generate the reversed Google URL scheme from it before building. If that
channel's ID is missing, **its iOS job fails early** rather than building a
binary that appears to have a working but mismatched callback. The other
platforms' builds do not need the iOS secret. For local iOS builds, put the
client ID matching the intended bundle ID into the ignored `.env` and run
`bash ios/Runner/generate_env_xcconfig.sh` before building. Each native
bundle ID needs its own Google iOS OAuth registration. Full setup:
`docs/ASTORIA_WINDOWS_DEV.md`.

Build outputs are 90-day workflow artifacts, not published GitHub Releases.
Optional Discord announcements link directly to the Actions run without Google
Drive. Automatic release publishing and Telegram delivery remain disabled; do
not equate channel `stable` with a permanent public binary release. Consult
`docs/WORKFLOW.md` before distribution.
