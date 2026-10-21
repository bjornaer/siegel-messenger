#!/bin/sh
# Runs on the Hetzner host as the forced command of the CI deploy key (docs/deploy.md).
# Wrapped in braces so sh parses it fully before git reset rewrites this file.
# `ssh deploy@host web < site.tar.gz` also installs a release of the web app (M8 part 5).
{
  set -eu
  cd "$(dirname "$0")/.."
  git fetch -q origin main
  git reset -q --hard origin/main
  mkdir -p web-site # ours, before compose would make it as root
  if [ "${SSH_ORIGINAL_COMMAND:-}" = "web" ]; then
    rev=$(git rev-parse --short HEAD)
    mkdir -p web-site/releases
    rm -rf "web-site/releases/$rev"
    mkdir "web-site/releases/$rev"
    tar -xzf - -C "web-site/releases/$rev" --no-same-owner
    ln -sfn "releases/$rev" web-site/current.new
    mv -T web-site/current.new web-site/current # one step: a load sees the old release or the new
    # Keep the last three releases, for a quick roll back.
    ls -1t web-site/releases | tail -n +4 | while read -r old; do rm -rf "web-site/releases/$old"; done
  fi
  docker compose up -d --build --wait --remove-orphans
  docker image prune -f >/dev/null
  echo "deployed $(git rev-parse --short HEAD)"
  exit
}
