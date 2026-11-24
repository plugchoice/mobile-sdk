#!/usr/bin/env bash
# Usage: osv-audit.sh <min-cvss> <osv-scanner arguments...>
# Runs osv-scanner (with osv-scanner.toml for exceptions), lists every advisory it finds and
# fails on one with a CVSS score of at least <min-cvss>, or with no score at all.
set -euo pipefail

min=$1
shift
out=$(mktemp)
rc=0
osv-scanner scan source --config osv-scanner.toml --format json --output-file "$out" "$@" || rc=$?
# 0: nothing found, 1: advisories found, anything else: the scan failed.
if [[ $rc -gt 1 ]]; then
  exit "$rc"
fi

jq -r '.results[]?.packages[]? | .package as $p | .groups[]?
  | "\($p.name) \($p.version): \(.ids | join(", ")) (CVSS \(if (.max_severity // "") == "" then "unknown" else .max_severity end))"' "$out"

if ! jq -e --argjson min "$min" '[.results[]?.packages[]?.groups[]?
  | select((.max_severity // "") == "" or ((.max_severity | tonumber) >= $min))] | length == 0' "$out" > /dev/null; then
  echo "::error::Advisories with a CVSS score of $min or more, or without a score (above). Update the package, or add an exception with its reason to osv-scanner.toml."
  exit 1
fi
echo "No advisory at CVSS $min or more."
