#!/usr/bin/env bash
# Runs a Flutter command with the iOS/macOS-only dependency manifest, then
# restores the platform-neutral pubspec and lockfile.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_PUBSPEC="$ROOT/pubspec.yaml"
APPLE_PUBSPEC="$ROOT/pubspec.apple.yaml"
LOCKFILE="$ROOT/pubspec.lock"
MUTEX_DIR="$ROOT/.dart_tool/apple-pubspec-mutex"

if [[ "$#" -eq 0 ]]; then
  echo "usage: bash tool/with_apple_pubspec.sh <flutter-command> [args...]" >&2
  exit 2
fi

if [[ "${1:-}" == "flutter" && "${2:-}" == "build" ]]; then
  case "${3:-}" in
    ios|macos) ;;
    *)
      echo "Apple manifest may only build ios or macos targets" >&2
      exit 2
      ;;
  esac
fi
if [[ "${1:-}" == "flutter" && "${2:-}" == "clean" ]]; then
  echo "flutter clean does not require the Apple dependency manifest" >&2
  exit 2
fi

mkdir -p "$ROOT/.dart_tool"
if ! mkdir "$MUTEX_DIR" 2>/dev/null; then
  echo "another Apple-manifest command is already using this checkout" >&2
  exit 1
fi
trap 'rmdir "$MUTEX_DIR"' EXIT

PUBSPEC_BAK="$(mktemp)"
LOCK_BAK="$(mktemp)"
LOCK_EXISTED=0
cp "$MAIN_PUBSPEC" "$PUBSPEC_BAK"
if [[ -f "$LOCKFILE" ]]; then
  cp "$LOCKFILE" "$LOCK_BAK"
  LOCK_EXISTED=1
fi

restore_pubspec() {
  cp "$PUBSPEC_BAK" "$MAIN_PUBSPEC"
  if [[ "$LOCK_EXISTED" -eq 1 ]]; then
    cp "$LOCK_BAK" "$LOCKFILE"
  else
    rm -f "$LOCKFILE"
  fi
  rm -f "$PUBSPEC_BAK" "$LOCK_BAK"
  rmdir "$MUTEX_DIR"
}
trap restore_pubspec EXIT

cp "$APPLE_PUBSPEC" "$MAIN_PUBSPEC"
cd "$ROOT"
flutter pub get
"$@"
