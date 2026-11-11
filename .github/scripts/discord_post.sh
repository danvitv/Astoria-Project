#!/usr/bin/env bash
# Posts a build announcement (with Google Drive download links) to the Astoria
# Discord release channels — RU (#версии) and EN (#releases) — via webhooks.
#
# Environment:
#   DISCORD_WEBHOOK_RU   webhook URL for the RU release channel   [required]
#   DISCORD_WEBHOOK_EN   webhook URL for the EN release channel   [required]
#   VERSION              build slug (tag or file slug)            [required]
#   BUILD_DATE           human-readable build date                [required]
#   BUILD_BRANCH         branch / channel                         [required]
#   BUILD_CHANNEL        stable|dev                               [default: dev]
#   COMMITS              optional markdown commit list
#   ANNOUNCEMENT_RU      optional RU preview/release note
#   ANNOUNCEMENT_EN      optional EN preview/release note
#   PING_ROLE_ID         optional Discord role ID to mention
#   LINKS_FILE           drive_upload.py output                   [default: drive_links.md]
set -euo pipefail

: "${DISCORD_WEBHOOK_RU:?DISCORD_WEBHOOK_RU is required}"
: "${DISCORD_WEBHOOK_EN:?DISCORD_WEBHOOK_EN is required}"
DISCORD_WEBHOOK_RU=$(printf '%s' "$DISCORD_WEBHOOK_RU" | tr -d '[:space:]')
DISCORD_WEBHOOK_EN=$(printf '%s' "$DISCORD_WEBHOOK_EN" | tr -d '[:space:]')
: "${VERSION:?VERSION is required}"
: "${BUILD_DATE:?BUILD_DATE is required}"
: "${BUILD_BRANCH:?BUILD_BRANCH is required}"
BUILD_CHANNEL="${BUILD_CHANNEL:-dev}"
LINKS_FILE="${LINKS_FILE:-drive_links.md}"
PING_ROLE_ID="${PING_ROLE_ID:-}"

COLOR=$((0xA855F7))

LINKS=""
if [ -s "$LINKS_FILE" ]; then
  LINKS=$(cat "$LINKS_FILE")
fi

# Unescape HTML entities produced by the metadata step for Telegram HTML mode.
CLEAN_COMMITS=$(printf '%s' "${COMMITS:-}" \
  | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')

CONTENT=""
if [ -n "$PING_ROLE_ID" ]; then
  CONTENT="<@&${PING_ROLE_ID}>"
fi

post() { # $1 = webhook url, $2 = title, $3 = description body, $4 = footer
  local url="$1" title="$2" body="$3" footer="$4"
  local payload
  payload=$(jq -n \
    --arg content "$CONTENT" \
    --arg title "$title" \
    --arg desc "$body" \
    --arg footer "$footer" \
    --argjson color "$COLOR" \
    '{
      content: (if $content == "" then null else $content end),
      embeds: [{
        title: $title,
        description: $desc,
        color: $color,
        footer: { text: $footer }
      }]
    }')
  local resp
  resp=$(curl -sS -X POST "$url" \
    -H 'Content-Type: application/json' -d "$payload")
  if [ -n "$resp" ] && [ "$(jq -r '.code // "0"' <<<"$resp")" != "0" ]; then
    echo "::warning::webhook rejected: $resp"
    return 1
  fi
  echo "posted announcement ($title)"
}

CHANNEL_LABEL="dev"
[ "$BUILD_CHANNEL" = "stable" ] && CHANNEL_LABEL="stable"

# ── RU (#версии) ───────────────────────────────────────────────────
RU_DESC=$(printf '**Дата сборки:** `%s UTC`\n**Ветка:** `%s` · **Канал:** `%s`' \
  "$BUILD_DATE" "$BUILD_BRANCH" "$CHANNEL_LABEL")
if [ -n "$LINKS" ]; then
  RU_DESC=$(printf '%s\n\n**📦 Скачать сборку (Google Drive):**\n%s' "$RU_DESC" "$LINKS")
fi
if [ -n "${ANNOUNCEMENT_RU:-}" ]; then
  RU_DESC=$(printf '%s\n\n%s' "$RU_DESC" "$ANNOUNCEMENT_RU")
fi
if [ -n "$CLEAN_COMMITS" ]; then
  RU_DESC=$(printf '%s\n\n**📝 Список изменений:**\n%s' "$RU_DESC" "$CLEAN_COMMITS")
fi
post "$DISCORD_WEBHOOK_RU" \
  "🚀 Новая сборка · Astoria $VERSION" \
  "$RU_DESC" \
  "Astoria Builds · На диске хранятся последние 3 сборки 🐈‍⬛"

# ── EN (#releases) ─────────────────────────────────────────────────
EN_DESC=$(printf '**Build date:** `%s UTC`\n**Branch:** `%s` · **Channel:** `%s`' \
  "$BUILD_DATE" "$BUILD_BRANCH" "$CHANNEL_LABEL")
if [ -n "$LINKS" ]; then
  EN_DESC=$(printf '%s\n\n**📦 Download build (Google Drive):**\n%s' "$EN_DESC" "$LINKS")
fi
if [ -n "${ANNOUNCEMENT_EN:-}" ]; then
  EN_DESC=$(printf '%s\n\n%s' "$EN_DESC" "$ANNOUNCEMENT_EN")
fi
if [ -n "$CLEAN_COMMITS" ]; then
  EN_DESC=$(printf '%s\n\n**📝 Changelog:**\n%s' "$EN_DESC" "$CLEAN_COMMITS")
fi
post "$DISCORD_WEBHOOK_EN" \
  "🚀 New build · Astoria $VERSION" \
  "$EN_DESC" \
  "Astoria Builds · Latest 3 builds are retained on Drive 🐈‍⬛"
