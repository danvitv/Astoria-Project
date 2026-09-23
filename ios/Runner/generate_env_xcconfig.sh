#!/bin/bash
# Reads .env and generates Runner/Configs/Env.xcconfig
# Run before invoking flutter build ios; xcconfig values are read before Xcode
# build phases execute.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"
XCCONFIG="$SCRIPT_DIR/Configs/Env.xcconfig"

DROPBOX_SCHEME="db-unknown"
GDRIVE_IOS_SCHEME="com.googleusercontent.apps.unknown"

if [ -f "$ENV_FILE" ]; then
  APP_KEY=$(sed -n 's/^DROPBOX_APP_KEY=//p' "$ENV_FILE" | head -1 | tr -d '[:space:]' | tr -d '"')
  if [ -n "$APP_KEY" ]; then
    case "$APP_KEY" in *[!a-zA-Z0-9_-]*) echo "Invalid Dropbox app key" >&2; exit 1 ;; esac
    DROPBOX_SCHEME="db-$APP_KEY"
  fi
  IOS_ID=$(sed -n 's/^GDRIVE_IOS_CLIENT_ID=//p' "$ENV_FILE" | head -1 | tr -d '[:space:]' | tr -d '"')
  if [ -n "$IOS_ID" ]; then
    case "$IOS_ID" in
      *.apps.googleusercontent.com)
        GDRIVE_IOS_SCHEME="com.googleusercontent.apps.${IOS_ID%.apps.googleusercontent.com}" ;;
      *) echo "Invalid Google iOS client ID" >&2; exit 1 ;;
    esac
    case "$GDRIVE_IOS_SCHEME" in *[!a-zA-Z0-9_.-]*) echo "Invalid Google iOS URL scheme" >&2; exit 1 ;; esac
  fi
fi

printf 'DROPBOX_URL_SCHEME = %s\nGDRIVE_IOS_URL_SCHEME = %s\n' \
  "$DROPBOX_SCHEME" "$GDRIVE_IOS_SCHEME" > "$XCCONFIG"
