#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s --tag=<vSemVer> --event-name=<event> --event-ref=<git-ref> [--main-ref=<git-ref>] [--expected-sha=<40-hex>]\n' "$0" >&2
}

tag=""
main_ref="refs/remotes/origin/main"
expected_sha=""
event_name=""
event_ref=""
for argument in "$@"; do
  case "$argument" in
    --tag=*) tag="${argument#--tag=}" ;;
    --main-ref=*) main_ref="${argument#--main-ref=}" ;;
    --expected-sha=*) expected_sha="${argument#--expected-sha=}" ;;
    --event-name=*) event_name="${argument#--event-name=}" ;;
    --event-ref=*) event_ref="${argument#--event-ref=}" ;;
    *) usage; exit 2 ;;
  esac
done

if [[ -z "$event_name" || -z "$event_ref" ]]; then
  usage
  exit 2
fi
if [[ "$event_name" == "workflow_dispatch" && "$event_ref" != "refs/heads/main" ]]; then
  printf 'release preflight: workflow_dispatch must be invoked from refs/heads/main, got %s\n' "$event_ref" >&2
  exit 1
fi

semver_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
if [[ ! "$tag" =~ $semver_pattern ]]; then
  printf 'release preflight: invalid SemVer tag: %s\n' "$tag" >&2
  exit 1
fi
prerelease="${BASH_REMATCH[5]:-}"
if [[ -n "$prerelease" ]]; then
  IFS='.' read -r -a prerelease_identifiers <<<"$prerelease"
  for identifier in "${prerelease_identifiers[@]}"; do
    if [[ "$identifier" =~ ^[0-9]+$ && "$identifier" =~ ^0[0-9]+$ ]]; then
      printf 'release preflight: numeric prerelease identifiers cannot have leading zeroes: %s\n' "$tag" >&2
      exit 1
    fi
  done
fi

tag_ref="refs/tags/$tag"
git show-ref --verify --quiet "$tag_ref" || {
  printf 'release preflight: tag does not exist: %s\n' "$tag_ref" >&2
  exit 1
}
git rev-parse --verify --quiet "${main_ref}^{commit}" >/dev/null || {
  printf 'release preflight: main ref does not exist or is not a commit: %s\n' "$main_ref" >&2
  exit 1
}

sha="$(git rev-parse --verify "${tag_ref}^{commit}")"
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  printf 'release preflight: tag did not resolve to an immutable commit SHA\n' >&2
  exit 1
fi
if ! git merge-base --is-ancestor "$sha" "$main_ref"; then
  printf 'release preflight: %s (%s) is not an ancestor of %s\n' "$tag" "$sha" "$main_ref" >&2
  exit 1
fi
if [[ -n "$expected_sha" && "$sha" != "$expected_sha" ]]; then
  printf 'release preflight: tag moved (expected %s, found %s)\n' "$expected_sha" "$sha" >&2
  exit 1
fi

printf 'release preflight: %s -> %s (ancestor of %s; event %s at %s)\n' "$tag" "$sha" "$main_ref" "$event_name" "$event_ref"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'tag=%s\nsha=%s\n' "$tag" "$sha" >>"$GITHUB_OUTPUT"
fi
