#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

git -C "$fixture" init --initial-branch=main --quiet
git -C "$fixture" config user.name "Preflight Test"
git -C "$fixture" config user.email "preflight@example.invalid"
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" config tag.gpgsign false
git -C "$fixture" commit --allow-empty --quiet -m initial
main_sha="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" tag v1.2.3
git -C "$fixture" tag v1.2.3-rc.1+build.5
git -C "$fixture" tag v1.2.3-01

git -C "$fixture" checkout --quiet -b side
git -C "$fixture" commit --allow-empty --quiet -m side
git -C "$fixture" tag v2.0.0
git -C "$fixture" checkout --quiet main

run_preflight() {
  (
    cd "$fixture"
    bash "$repo_root/scripts/release-preflight.sh" "$@"
  )
}

run_preflight --tag=v1.2.3 --event-name=push --event-ref=refs/tags/v1.2.3 --main-ref=refs/heads/main --expected-sha="$main_sha" >/dev/null
run_preflight --tag=v1.2.3-rc.1+build.5 --event-name=push --event-ref=refs/tags/v1.2.3-rc.1+build.5 --main-ref=refs/heads/main --expected-sha="$main_sha" >/dev/null
run_preflight --tag=v1.2.3 --event-name=workflow_dispatch --event-ref=refs/heads/main --main-ref=refs/heads/main >/dev/null

if run_preflight --tag=1.2.3 --event-name=push --event-ref=refs/tags/1.2.3 --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected invalid tag syntax to fail\n' >&2
  exit 1
fi
if run_preflight --tag=v1.2.3-01 --event-name=push --event-ref=refs/tags/v1.2.3-01 --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected SemVer numeric prerelease with a leading zero to fail\n' >&2
  exit 1
fi
if run_preflight --tag=v9.9.9 --event-name=push --event-ref=refs/tags/v9.9.9 --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected missing tag to fail\n' >&2
  exit 1
fi
if run_preflight --tag=v2.0.0 --event-name=push --event-ref=refs/tags/v2.0.0 --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected non-main tag to fail\n' >&2
  exit 1
fi
if run_preflight --tag=v1.2.3 --event-name=push --event-ref=refs/tags/v1.2.3 --main-ref=refs/heads/main --expected-sha="$(printf 'f%.0s' {1..40})" >/dev/null 2>&1; then
  printf 'expected moved tag check to fail\n' >&2
  exit 1
fi

if run_preflight --tag=v1.2.3 --event-name=workflow_dispatch --event-ref=refs/heads/side --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected workflow_dispatch from a non-main ref to fail\n' >&2
  exit 1
fi
if run_preflight --tag=v1.2.3 --main-ref=refs/heads/main >/dev/null 2>&1; then
  printf 'expected missing explicit event context to fail\n' >&2
  exit 1
fi

printf 'release preflight tests: event/ref gate, syntax, existence, ancestry, and pinned SHA passed\n'
