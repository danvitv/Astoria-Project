#!/bin/bash
# Generates platform-specific config from .env
# Run before: flutter build ios / flutter build apk
#
# Android: reads .env at Gradle time (no manual step needed)
# iOS: generates ios/Runner/Configs/Env.xcconfig

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/ios/Runner/generate_env_xcconfig.sh"
