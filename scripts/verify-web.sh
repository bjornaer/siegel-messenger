#!/bin/sh
# Checks that the web app you are served is the one CI built from this repository (M8 part 5):
# GitHub's attestation (Sigstore) ties the manifest to a commit, and every served file must
# match the manifest. Needs curl, the GitHub CLI (gh) and sha256sum or shasum.
#   scripts/verify-web.sh [https://web.siegel.schlk.in]
set -eu
site=${1:-https://web.siegel.schlk.in}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

curl -fsS "$site/.well-known/siegel-web-manifest.txt" -o "$dir/manifest.txt"
gh attestation verify "$dir/manifest.txt" --repo bjornaer/siegel-messenger
echo "manifest sha256 $(sum "$dir/manifest.txt"): https://siegel.schlk.in/transparency shows the one served now"

bad=0
n=0
while read -r want file; do
  n=$((n + 1))
  curl -fsS "$site/$file" -o "$dir/file" || { echo "missing: $file"; bad=1; continue; }
  [ "$(sum "$dir/file")" = "$want" ] || { echo "DIFFERENT: $file"; bad=1; }
done < "$dir/manifest.txt"
[ "$bad" = 0 ] && echo "all $n files match the attested build" || { echo "the served site does NOT match"; exit 1; }
