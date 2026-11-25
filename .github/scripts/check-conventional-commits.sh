#!/usr/bin/env bash
# Every commit subject (and a pull request's title) must be a conventional
# commit: type(optional-scope)!: description. A pull request's commits carry no
# attribution: no Co-authored-by or Claude-Session trailer, no "Generated with"
# line and no claude.ai/code session link. Merge commits are skipped.
set -euo pipefail

pattern='^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([a-z0-9._/-]+\))?!?: [^ ].*'
attribution='^[[:space:]]*(co-authored-by|claude-session):|^[^[:alnum:]]*generated with|claude\.ai/code/session_'
failed=0
attributed=0

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

for commit in $(git log --no-merges --format=%h $range); do
  check "$(git log -1 --format=%s "$commit")"
  # Only a pull request's commits: squash-merging a bot's pull request makes
  # GitHub add its own Co-authored-by trailer to the commit on main.
  if [[ -n "${PR_TITLE:-}" ]]; then
    while IFS= read -r line; do
      echo "::error::Commit $commit carries attribution: $line"
      attributed=1
    done < <(git log -1 --format=%B "$commit" | grep -iE "$attribution")
  fi
done

if [[ $failed -ne 0 ]]; then
  echo "Use type(scope): description, with type one of build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test. See https://www.conventionalcommits.org."
fi
if [[ $attributed -ne 0 ]]; then
  echo "Commits carry no attribution: reword them without the lines above."
fi
if [[ $failed -ne 0 || $attributed -ne 0 ]]; then
  exit 1
fi
echo "All commits are conventional."
