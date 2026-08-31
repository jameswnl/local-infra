#!/usr/bin/env bash
# Verifies a git repo's checked-out HEAD matches origin/main and the tree
# is clean, so make targets that build container images never bake in
# stale or uncommitted source without the caller knowing. Prints HEAD's
# short SHA to stdout on success (or on FORCE=1 override) -- callers use
# that SHA as an image tag.
#
# Usage: check-clean-main.sh <repo-path>
# Set FORCE=1 to skip the check (still prints a warning to stderr).
set -euo pipefail

REPO_PATH="${1:?usage: check-clean-main.sh <repo-path>}"

git -C "$REPO_PATH" fetch origin main --quiet
LOCAL_SHA=$(git -C "$REPO_PATH" rev-parse HEAD)
MAIN_SHA=$(git -C "$REPO_PATH" rev-parse origin/main)
DIRTY=$(git -C "$REPO_PATH" status --porcelain)

if [ "${FORCE:-0}" = "1" ]; then
  if [ "$LOCAL_SHA" != "$MAIN_SHA" ] || [ -n "$DIRTY" ]; then
    echo "warning: FORCE=1 -- building $REPO_PATH from a non-main/dirty checkout ($LOCAL_SHA)" >&2
  fi
else
  if [ "$LOCAL_SHA" != "$MAIN_SHA" ]; then
    echo "error: $REPO_PATH is not on latest origin/main (HEAD=$LOCAL_SHA, origin/main=$MAIN_SHA)." >&2
    echo "  Run: git -C $REPO_PATH checkout main && git -C $REPO_PATH pull" >&2
    echo "  Or set FORCE=1 to build from the current checkout anyway." >&2
    exit 1
  fi
  if [ -n "$DIRTY" ]; then
    echo "error: $REPO_PATH has uncommitted changes:" >&2
    echo "$DIRTY" >&2
    echo "  Commit or stash them, or set FORCE=1 to build anyway." >&2
    exit 1
  fi
fi

git -C "$REPO_PATH" rev-parse --short=12 HEAD
