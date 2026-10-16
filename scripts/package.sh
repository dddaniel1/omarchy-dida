#!/usr/bin/env bash
# Package the current working copy, including changes not committed to git.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  printf 'Usage: scripts/package.sh\n\nCreate dist/<plugin-id>-<version>.tar.gz from this working copy.\n'
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'Unexpected argument: %s\n' "$1" >&2; exit 1; }

cd "$ROOT"
python3 tests/validate_manifest.py
ID="$(python3 -c 'import json; print(json.load(open("manifest.json"))["id"])')"
VERSION="$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')"
[[ $ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  printf 'Invalid plugin id or version for archive filename\n' >&2
  exit 1
}

mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf -- "$STAGE"' EXIT
mkdir -p "$STAGE/$ID/scripts"
cp -a manifest.json bin qml ticktick LICENSE NOTICE README.md .gitignore "$STAGE/$ID/"
cp -a scripts/install.sh "$STAGE/$ID/scripts/"
# Explicit runtime files avoid shipping credentials, caches, or local tool state.
find "$STAGE/$ID/ticktick" -type f ! -name '*.py' -delete
find "$STAGE/$ID/ticktick" -type d -name __pycache__ -empty -delete
tar -czf "$STAGE/package.tar.gz" -C "$STAGE" "$ID"
mv -- "$STAGE/package.tar.gz" "dist/$ID-$VERSION.tar.gz"
printf 'Packaged %s/dist/%s-%s.tar.gz\n' "$ROOT" "$ID" "$VERSION"
