#!/usr/bin/env bash
# Run the Android helper's dependency-free java.time checks on the local JDK.
set -euo pipefail

client_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
zone_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/elecon-zone-tests.XXXXXX")"
trap 'rm -rf -- "$zone_test_dir"' EXIT

javac -d "$zone_test_dir" \
  "$client_dir/android/app/src/main/java/com/ncclab/elecon/SchoolQueryTimeZone.java" \
  "$client_dir/android/app/src/test/java/com/ncclab/elecon/SchoolQueryTimeZoneTest.java"
java -cp "$zone_test_dir" com.ncclab.elecon.SchoolQueryTimeZoneTest
