#!/usr/bin/env bash
# The Android library's part of the dependency audit (.github/workflows/audit.yml). Run it from
# the repository root; it needs Java 17, the Android SDK, osv-scanner and jq.
#
# osv-scanner reads Gradle lockfiles only, and the library has none (React Native host apps build
# the same build file), so gradle-lock.init.gradle.kts locks the release runtime classpath (what an
# app gets) and the unit-test classpath for this run. The Gradle plugins' own dependencies are not
# checked: they run only while building, and move with the plugin versions Dependabot updates.
set -euo pipefail

lockfile=android/plugchoice/gradle.lockfile
release=$(mktemp)
# --write-locks also writes an empty lock state for the settings script.
trap 'rm -f "$lockfile" "$release" android/settings-gradle.lockfile' EXIT

(cd android && ./gradlew --quiet -I ../.github/scripts/gradle-lock.init.gradle.kts \
  :plugchoice:dependencies --write-locks > /dev/null)
grep -E '^#|releaseRuntimeClasspath|^empty=' "$lockfile" > "$release"

status=0
echo "Release runtime classpath (fails at CVSS 7):"
.github/scripts/osv-audit.sh 7 -L "gradle.lockfile:$release" || status=1
echo "With the unit-test classpath (fails at CVSS 9):"
.github/scripts/osv-audit.sh 9 -L "gradle.lockfile:$lockfile" || status=1
exit $status
