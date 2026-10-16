#!/usr/bin/env bash
# Install this checkout as the Omarchy shell plugin its manifest names. See --help.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGINS_DIR="${OMARCHY_PLUGINS_DIR:-$HOME/.config/omarchy/plugins}"

fail() { printf '\033[31merror\033[0m %s\n' "$1" >&2; exit 1; }
info() { printf '\033[2m  %s\033[0m\n' "$1"; }
ok() { printf '\033[32mok\033[0m %s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: scripts/install.sh [options]

Install this checkout as the Omarchy shell plugin that manifest.json names.

Without a flag the plugin directory gets a *snapshot*: the working tree is copied
into it, so the installed widget stays exactly as it is while you carry on editing
the checkout. Re-run the script whenever you want to publish what you changed.

  --link        Link the plugin directory at this checkout instead, so the shell
                reads it live and saving a .qml rebuilds the widget by itself.
  --force, -f   Replace an existing plugin directory that is a git checkout
                ('omarchy plugin add' made it; its git metadata would be lost).
  --no-reload   Install only. Skip enabling the plugin and asking the shell to
                pick it up.
  -h, --help    This text.

The plugin id comes from manifest.json, and the checkout is validated against the
Omarchy plugin schema before anything is written.
EOF
}

need() { command -v "$1" >/dev/null || fail "$1 is required but is not on PATH"; }

LINK=0
FORCE=0
RELOAD=1

while (( $# > 0 )); do
  case "$1" in
  --link) LINK=1 ;;
  --force | -f) FORCE=1 ;;
  --no-reload) RELOAD=0 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) fail "unknown option '$1' (--help lists them)" ;;
  esac
  shift
done

need omarchy
need jq
need python3
((LINK)) || need rsync
((RELOAD == 0)) || need omarchy-shell

[[ -f $ROOT/manifest.json ]] || fail "no manifest.json in $ROOT"

# The install directory is the manifest's id, not the checkout's name, because that
# is how 'omarchy plugin add' files it: the two disagreeing would leave the shell
# discovering the plugin under one name while the manifest claimed another.
ID="$(jq -r '.id // ""' "$ROOT/manifest.json")"
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "manifest id '$ID' is not a valid plugin id"

DEST="$PLUGINS_DIR/$ID"
[[ $DEST == "$PLUGINS_DIR/"* ]] || fail "refusing to install outside $PLUGINS_DIR"
[[ $DEST != "$ROOT" ]] || fail "the plugin directory is this checkout"

info "validating $ROOT"
omarchy plugin validate "$ROOT" || fail "manifest.json does not pass 'omarchy plugin validate'"

mkdir -p "$PLUGINS_DIR"

# A symlink is removed, never followed: 'rm' on one unlinks it and leaves the
# checkout it points at alone.
if [[ -L $DEST ]]; then
  info "replacing the symlink at $DEST"
  rm -f -- "$DEST"
elif [[ -e $DEST && ! -d $DEST ]]; then
  fail "$DEST exists and is not a directory"
elif [[ -d $DEST/.git && $FORCE -eq 0 ]]; then
  fail "$DEST is a git checkout; pass --force to replace it"
fi

if ((LINK)); then
  [[ -d $DEST ]] && rm -rf -- "$DEST"
  ln -s "$ROOT" "$DEST"
  info "linked $DEST -> $ROOT"
else
  mkdir -p "$DEST"
  # .gitignore is the list of what this plugin must not ship — caches, credentials,
  # the local tool state — so the copy cannot drift from it. Excluded files are
  # deleted from the destination too, so a re-run is a mirror rather than a merge.
  rsync -a --delete --delete-excluded --exclude '.git/' \
    --filter=':- .gitignore' "$ROOT"/ "$DEST"/
  info "copied the working tree into $DEST"
fi

if ((RELOAD)); then
  omarchy-shell shell rescanPlugins
  # Only a plugin the shell has never seen is enabled. Re-enabling one that is
  # already in the bar would move it to the end of its section.
  if [[ "$(omarchy plugin list --json |
    jq -r --arg id "$ID" '.[] | select(.id == $id) | .enabled')" != "true" ]]; then
    SECTION="$(jq -r '.barWidget.defaultSection // "right"' "$ROOT/manifest.json")"
    omarchy plugin enable "$ID" --section "$SECTION"
  fi
fi

ok "installed $ID at $DEST"
