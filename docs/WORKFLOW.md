# Astoria workflow

Git, branching, checks and build distribution for the private standalone
`danvitv/Astoria-Project` repository. The full Git history of the Glaze-derived
project is preserved here; history preservation does not authorize publishing
it. `origin` points only to this private repository. Never open a PR against or
push Astoria work to `hydall/Glaze`, `danvitv/Glaze`, or the public
`danvitv/Astoria-Project-Release` repository.

## Branches

| Branch | Build channel | Purpose |
|---|---|---|
| `dev` | `dev` | Default branch, current development and internal builds |
| `release` | `stable` | Reserved for tested releases; not created yet |
| `feat/*`, `fix/*` | `nightly` when built by CI | Optional isolated work based on `dev` |

When asked to work directly on `dev`, verify the branch and push only to
`origin/dev` after appropriate checks. Otherwise start an isolated branch from
`origin/dev` and open any PR **in Astoria**, with base `dev`. Do not base new
Astoria work on the leftover local `nightly`/`stable` branches from the Glaze
history. Preserve authorship and existing history; do not force-push shared
branches. Regenerate after editing a Freezed/Drift model with
`dart run build_runner build`.

`release` can be cut from a tested `dev` revision only when the maintainer
requests it. Building from that branch alone does not publish a release. Follow
`docs/ASTORIA_LICENSE_AUDIT.md` before distributing proprietary binaries.

## Checks

`.github/workflows/ci.yml` runs on PRs targeting `dev` or `release` (and may
also be triggered manually). It runs `flutter analyze` (only analyzer errors
are fatal), the Flutter tests, the DB migration suite separately, the WebView
render suite, and the bug-triage tests. Direct pushes to `dev` do **not**
automatically trigger PR CI; check the affected code locally or run CI
manually. Record which checks actually ran. Do not commit `.env`, OAuth
credentials, signing keys or local user data.

For WebView rendering tests: `cd test/webview_js && npm ci && npx playwright
install chromium && npm test`. See `docs/rules/message-rendering.md` for the
rendering regression corpus. `flutter run` is interactive and belongs in a
user terminal; see `CLAUDE.md`.

## Build distribution

Start **Build (Branch)** (`.github/workflows/build-branch.yml`) from GitHub
Actions with **Use workflow from: dev**, selecting the platforms needed. It
uploads build artifacts to that private workflow run; it does not release
anything publicly. CI supplies `.env` from repository Actions secrets. Channel
identities, data paths and Google OAuth client selection are documented in
`docs/RELEASE_CHANNELS.md` and `docs/ASTORIA_WINDOWS_DEV.md`. Verify Android
and Windows builds on actual devices before promoting a release; iOS builds are
currently unsigned and require an Apple signing or re-signing setup before
installation.

**Build Release (Artifacts only)** (`.github/workflows/build-release.yml`)
also only uploads private run artifacts. Its GitHub Release job and the old
Telegram delivery jobs are disabled. There are no public binaries yet. The
public `danvitv/Astoria-Project-Release` repository currently hosts the
README, logo and Our Picks feed, not the private source or Git history.

Do not turn on automatic public binary distribution by repointing the old
same-repository release job. Establish publication rights, dependency notices,
destination credentials and a public release process first; see
`docs/ASTORIA_LICENSE_AUDIT.md`.
