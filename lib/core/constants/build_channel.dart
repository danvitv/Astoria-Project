/// Release channel this build was produced for.
///
/// Injected by the CI workflow (`--dart-define=BUILD_CHANNEL=<name>`), which
/// derives it from the branch being built:
///
/// | branch                   | channel  |
/// |--------------------------|----------|
/// | `main` / `master`        | `stable` |
/// | `dev` / working branches | `dev`    |
///
/// Defaults to `dev` so local developer builds use the Astoria-dev data root.
///
/// The channel no longer decides whether developer mode is on — that is off by
/// default everywhere and is unlocked through the version-badge easter egg in
/// About. What is left is packaging (data folder, cloud root, update source)
/// and the build-watermark default.
const buildChannel = String.fromEnvironment(
  'BUILD_CHANNEL',
  defaultValue: 'dev',
);

/// Whether this is a production (`stable`) build.
const isStableChannel = buildChannel == 'stable';

/// Astoria desktop data and cloud namespaces. Local builds use the dev channel.
/// Mobile app IDs already isolate channels, so their sandbox folder is Astoria.
const astoriaDataFolderName = isStableChannel
    ? 'Astoria'
    : 'Astoria-$buildChannel';
