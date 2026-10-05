#!/usr/bin/env bash
# Install ForeverAuras at a committed ref onto the gaming box over ssh (FORK.md, "Installing on the box").
#   tools/box-install.sh [--ref <git-ref>] [--dry-run]
# Writes only Interface/AddOns/ForeverAuras* on the box. Never WTF/, never SavedVariables, never starts or stops WoW.
set -euo pipefail

REF=HEAD
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "box-install: unknown argument: $1" >&2; exit 2 ;;
  esac
done

ROOT=$(git -C "$(dirname "$0")/.." rev-parse --show-toplevel)
FOLDERS="ForeverAuras ForeverAurasOptions ForeverAurasArchive ForeverAurasModelPaths ForeverAurasTemplates"

# Host and client folder are private to one machine: from env, else the same per-user file Unasphere's box tools use.
ENV_FILE="${FA_BOX_ENV:-${UNASPHERE_BOX_ENV:-$HOME/.config/unasphere/box.env}}"
if [ -f "$ENV_FILE" ]; then set -a; . "$ENV_FILE"; set +a; fi
HOST="${FA_BOX_HOST:-${UNASPHERE_BOX_HOST:-}}"
WOW="${FA_BOX_WOW:-${UNASPHERE_BOX_WOW:-}}"
if [ -z "$HOST" ] || [ -z "$WOW" ]; then
  echo "box-install: set FA_BOX_HOST and FA_BOX_WOW (the client folder holding Interface/), or put UNASPHERE_BOX_HOST/" \
       "UNASPHERE_BOX_WOW in $ENV_FILE" >&2
  exit 2
fi
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
q() { printf '%q ' "$@"; }

SHA=$(git -C "$ROOT" rev-parse --verify "$REF^{commit}")
if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
  echo "box-install: note: uncommitted changes are NOT installed; installing $SHA" >&2
fi

# Libraries: ForeverAuras/Libs from the pinned upstream release, sha256-checked.
TAG=$(sed -n 's/^tag=//p' "$ROOT/tools/libs.lock")
WANT=$(sed -n 's/^sha256=//p' "$ROOT/tools/libs.lock")
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/foreverauras"
ZIP="$CACHE/ForeverAuras-$TAG.zip"
mkdir -p "$CACHE"
if [ ! -f "$ZIP" ]; then
  curl -fsSL -o "$ZIP.part" "https://github.com/neroxrw/foreverauras/releases/download/$TAG/ForeverAuras-$TAG.zip"
  mv "$ZIP.part" "$ZIP"
fi
GOT=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
if [ "$GOT" != "$WANT" ]; then
  echo "box-install: $ZIP sha256 $GOT != libs.lock $WANT; refusing" >&2
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# shellcheck disable=SC2086
git -C "$ROOT" archive "$SHA" $FOLDERS | tar -x -C "$STAGE"
unzip -q -o "$ZIP" 'ForeverAuras/Libs/*' -d "$STAGE"
printf '%s\n' "$SHA" > "$STAGE/ForeverAuras/.installed-sha"

# Every Lua file must compile (LuaJIT parses Lua 5.1) before anything reaches the box. ModelPaths is one generated
# data table with more constants than LuaJIT allows (WoW's Lua takes it), so it is skipped.
if command -v luajit >/dev/null; then
  find "$STAGE" -name '*.lua' ! -path '*/ForeverAurasModelPaths/*' -print0 | xargs -0 -n 50 sh -c 'for f; do luajit -b "$f" /dev/null || exit 255; done' sh
else
  echo "box-install: luajit not found; skipping the compile check" >&2
fi

manifest_local() { (cd "$STAGE" && find $FOLDERS -type f -print0 | xargs -0 md5 -r) | sed -E 's/^([0-9a-f]{32}) +/\1 /' | LC_ALL=C sort; }
manifest_box() {
  $SSH "$HOST" "cd $(q "$WOW/Interface/AddOns") && for f in $FOLDERS; do [ -d \"\$f\" ] && find \"\$f\" -type f -print0; done | xargs -0 -r md5sum" \
    | sed -E 's/^([0-9a-f]{32}) +/\1 /' | LC_ALL=C sort
}

LOCAL=$(manifest_local)
BEFORE=$(manifest_box)
FIRST=1
case "$BEFORE" in *" ForeverAuras/.installed-sha"*) FIRST=0 ;; esac
CHANGED=$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$LOCAL") | grep -c '^[<>]' || true)
echo "box-install: $SHA ($(printf '%s\n' "$LOCAL" | wc -l | tr -d ' ') files, $CHANGED manifest lines differ from the box)"
if [ "$DRY" = 1 ]; then
  diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$LOCAL") | grep '^[<>]' | head -40 || true
  exit 0
fi

# Copy to a staging dir on the box, then rsync each folder into AddOns: everything but .toc first (with --delete, so
# files retired at this sha go), .toc files last, so a /reload mid-copy never loads a half-updated addon.
BOXSTAGE='.cache/foreverauras-stage'
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf - $FOLDERS) | \
  $SSH "$HOST" "rm -rf $BOXSTAGE && mkdir -p $BOXSTAGE && tar -xzf - -C $BOXSTAGE"
$SSH "$HOST" "bash -s -- $(q "$WOW/Interface/AddOns") $FOLDERS" <<'EOF'
set -euo pipefail
dest="$1"; shift
[ -d "$dest" ] || { echo "box-install: no AddOns folder at $dest" >&2; exit 1; }
for f in "$@"; do
  rsync -a --checksum --delete --exclude='*.toc' "$HOME/.cache/foreverauras-stage/$f/" "$dest/$f/"
done
for f in "$@"; do
  rsync -a --checksum --include='*/' --include='*.toc' --exclude='*' "$HOME/.cache/foreverauras-stage/$f/" "$dest/$f/"
done
rm -rf "$HOME/.cache/foreverauras-stage"
EOF

AFTER=$(manifest_box)
if [ "$AFTER" != "$LOCAL" ]; then
  echo "box-install: FAILED verification: the box's files differ from $SHA" >&2
  diff <(printf '%s\n' "$AFTER") <(printf '%s\n' "$LOCAL") | head -20 >&2
  exit 1
fi
RUNNING=no
if $SSH "$HOST" "pgrep -f '[W]owB\.exe' >/dev/null"; then RUNNING=yes; fi
echo "box-install: installed and verified $SHA (md5 of every file matches)."
if [ "$FIRST" = 1 ]; then
  echo "box-install: first install: WoW only finds new addons at startup. Restart WoW, then enable ForeverAuras in the AddOns list."
elif [ "$RUNNING" = yes ]; then
  echo "box-install: WoW is running: /reload to load it (a new .lua file needs a WoW restart)."
fi
