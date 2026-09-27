#!/usr/bin/env bash
# Clone one upstream repo at an exact pinned SHA, shallow.
# Usage: clone.sh <name> <github-org/repo> <sha>
set -euo pipefail

name="$1"; repo="$2"; sha="$3"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/repos/$name"

if [ -d "$dest/.git" ]; then
  echo "[$name] already cloned"
  exit 0
fi

mkdir -p "$dest"
cd "$dest"
git init -q
git remote add origin "https://github.com/$repo.git"
# Shallow fetch of a single commit: avoids full history on a 9p filesystem.
git fetch -q --depth 1 origin "$sha"
git checkout -q FETCH_HEAD

actual="$(git rev-parse HEAD)"
if [ "$actual" != "$sha" ]; then
  echo "[$name] SHA MISMATCH: wanted $sha got $actual" >&2
  exit 1
fi
echo "[$name] OK $actual  $(git log -1 --format=%cI)"
