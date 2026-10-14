#!/bin/sh
# Runs on the Hetzner host as the forced command of the CI deploy key (docs/deploy.md).
# Wrapped in braces so sh parses it fully before git reset rewrites this file.
{
  set -eu
  cd "$(dirname "$0")/.."
  git fetch -q origin main
  git reset -q --hard origin/main
  docker compose up -d --build --wait --remove-orphans
  docker image prune -f >/dev/null
  echo "deployed $(git rev-parse --short HEAD)"
  exit
}
