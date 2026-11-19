# Astoria: release rights checklist

This is a working inventory for binary releases and any future proprietary
distribution. The Astoria source repository and its retained Glaze history are
public under AGPL-3.0; that publication does not relicense third-party materials
or clear a closed-source release.

## App code and history

- The public repository retains Glaze's full commit history and its AGPL-3.0
  `LICENSE`. Source publication satisfies the chosen open-source direction but
  does not by itself satisfy platform packaging, attribution or corresponding-
  source obligations for a particular binary release.
- Obtain a written grant from the holders of *all* incorporated app code before
  distributing a closed-source derivative. The grant from Hydall should
  explicitly cover his Glaze contributions, contributions made under his other
  accounts, any incorporated Glaze Vue code and the JAR-origin code, and permit
  modification and distribution of proprietary binaries without publishing the
  app's source. Keep the scope and effective versions/revisions unambiguous.
- The public history contains earlier versions of bundled third-party presets
  and the SillyTavern ComfyUI template. The maintainer explicitly chose to retain
  and publish that history. Their presence does not place those third-party
  materials under Astoria's AGPL licence; provenance and upstream terms still
  need to be respected when reusing or packaging them.

## Incorporated materials

- Four third-party preset JSON files and their covers (Shino, Fawnie,
  MicroCoT, Renri) were removed from the shipped assets and first-run seeding.
  Existing user-imported or already seeded database entries are not removed.
- The default ComfyUI graph was replaced with a small graph assembled from
  standard ComfyUI nodes. Existing user-supplied workflows are preserved.
- Some Dart code describes ports or behavioural compatibility with SillyTavern,
  Marinara-Engine and SillyImages. A comment or compatible wire format is not
  proof of copied copyrightable expression. Review any substantially copied
  code against its upstream implementation before proprietary distribution;
  obtain permission or replace it if needed. In particular, the JAR-derived
  Janitor extraction code needs to be included in the Hydall grant.
- `lib/shared/widgets/stretch_overscroll.dart` describes a verbatim Flutter
  framework port. Flutter's BSD-3-Clause notice must be retained for it; that
  licence does not require publishing the app's own source.
- `assets/fonts/InterVariable.ttf` is the Inter font under SIL OFL 1.1. Ship
  its copyright and licence notice with distributed builds.
- Provider logos remain in the app. Their use and applicable branding policies
  should be reviewed for the new name; they were not removed in this audit.
- Picks are downloaded at runtime from the public
  `danvitv/Astoria-Project-Release` catalog via
  `lib/features/picks/picks_provider.dart`, rather than bundled as app assets.
  Review any hosted third-party cards before announcing the catalog broadly.

## Dependencies and release packaging

- The current pub dependency graph uses hosted packages plus Flutter SDK
  packages, not Git/path dependencies. The cached Dart packages reviewed are
  predominantly MIT/BSD/Apache-licensed. Linux packages `dbus` and `gtk` are
  MPL-2.0: comply with their file-level source/notice terms if distributing
  builds that include them. The `archive` package has additional notices in
  its `LICENSE-other.md`.
- Check the exact dependency graph and shipped native libraries separately for
  each target platform/build. Bundle the applicable third-party licence and
  attribution texts with the binaries; recheck after dependency updates.
- The current `LICENSE`, about screen and translations still describe the
  project's AGPL status. Build workflows now produce Astoria-named artifacts,
  but public release publishing and Telegram delivery are disabled until their
  destinations and corresponding-source/licensing obligations are resolved.
  Do not switch licence labels to proprietary or distribute closed binaries
  until the rights grant, remaining provenance review, third-party notices and
  release pipeline are done.
