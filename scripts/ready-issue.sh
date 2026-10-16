#!/usr/bin/env bash
# Keeps the one "Ready for testing" issue (label: channels) in line with the report from
# `flockrel manifest -status <file>`: creates or updates it while builds are pending, closes it when
# none are. Builds newly waiting for a decision get a comment, so the update notifies.
# Usage: scripts/ready-issue.sh <status-file>     (GH_TOKEN, GH_REPO set; <status-file>.waiting next to it)
set -euo pipefail
STATUS="${1:?usage: ready-issue.sh <status-file>}"
title="Ready for testing"
label=channels

gh label create "$label" --color 1d76db --force \
  --description "Builds waiting in the beta or experimental channel" >/dev/null
# The REST list (not search, which can lag behind); should there ever be two, keep the oldest.
mapfile -t open < <(gh api "repos/$GH_REPO/issues?state=open&labels=$label&per_page=100" \
  --jq ".[] | select(.title == \"$title\") | .number" | sort -n)
number="${open[0]:-}"
for extra in "${open[@]:1}"; do
  gh issue close "$extra" --comment "Duplicate of #$number." >/dev/null && echo "closed duplicate #$extra"
done

if [[ ! -s "$STATUS" ]]; then
  if [[ -n "$number" ]]; then
    gh issue close "$number" --comment "Nothing pending anymore: every build is in its final channel."
    echo "closed #$number"
  fi
  exit 0
fi

if [[ -z "$number" ]]; then
  url="$(gh issue create --title "$title" --label "$label" --body-file "$STATUS")"
  echo "created $url"
  exit 0
fi
old="$(gh issue view "$number" --json body --jq .body)"
gh issue edit "$number" --body-file "$STATUS" >/dev/null
echo "updated #$number"
# Editing a body notifies nobody: mention what newly waits for a decision in a comment.
new=()
while read -r build; do
  [[ -n "$build" && "$old" != *"\`$build\`"* ]] && new+=("$build")
done < "$STATUS.waiting"
if [[ ${#new[@]} -gt 0 ]]; then
  { echo "New builds waiting for a decision:"; echo; printf -- '- `%s`\n' "${new[@]}"; } | gh issue comment "$number" --body-file -
  echo "commented on #$number: ${new[*]}"
fi
