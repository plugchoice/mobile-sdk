#!/usr/bin/env bash
# Every commit subject (and a pull request's title) must be a conventional
# commit: type(optional-scope)!: description. Merge commits are skipped.
set -euo pipefail

pattern='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9._/-]+\))?!?: [^ ].*'
failed=0

check() {
  if [[ ! "$1" =~ $pattern ]]; then
    echo "::error::Not a conventional commit: $1"
    failed=1
  fi
}

if [[ -n "${PR_TITLE:-}" ]]; then
  check "$PR_TITLE"
fi

if [[ -n "${BASE:-}" && "$BASE" != 0000000000000000000000000000000000000000 ]]; then
  range="$BASE..$HEAD"
else
  range="$HEAD -1"
fi

while IFS= read -r subject; do
  check "$subject"
done < <(git log --no-merges --format=%s $range)

if [[ $failed -ne 0 ]]; then
  echo "Use type(scope): description, with type one of build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test. See https://www.conventionalcommits.org."
  exit 1
fi
echo "All commits are conventional."
