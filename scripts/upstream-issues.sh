#!/usr/bin/env bash
# Turns the findings of `flockrel check` into issues (label: upstream):
#   new release lines, end of life  one issue each, found by title. Never reported twice: a closed
#                                   issue means "decided", so it stays closed. An open one whose
#                                   finding is gone (the line was added or removed) is closed.
#   pinned versions                 one issue, updated with every run; new updates get a comment. Closed
#                                   by hand, it stays closed until an update it didn't list comes.
# Usage: scripts/upstream-issues.sh <findings.json>     (GH_TOKEN, GH_REPO set)
set -euo pipefail
FINDINGS="${1:?usage: upstream-issues.sh <findings.json>}"
label=upstream
pins_title="Updates available for pinned versions"

gh label create "$label" --color 5319e7 --force \
  --description "New upstream releases and end-of-life notices (weekly check)" >/dev/null
# number, state, title of every issue with the label, newest first.
existing="$(gh api --paginate "repos/$GH_REPO/issues?state=all&labels=$label&per_page=100" \
  --jq '.[] | select(.pull_request | not) | [.number, .state, .title] | @tsv' | sort -t$'\t' -k1,1nr)"
lookup() { awk -F'\t' -v t="$1" '$3 == t {print $1 "\t" $2; exit}' <<<"$existing"; }
rows() { grep '^| ' <<<"$1" | grep -v -e '^| What ' -e '^|---' | sort || true; }

# New lines and end of life.
while IFS=$'\t' read -r title body; do
  body="$(printf '%b' "$body")"
  hit="$(lookup "$title")"
  if [[ -z "$hit" ]]; then
    gh issue create --title "$title" --label "$label" --body "$body" >/dev/null
    echo "created: $title"
  elif [[ "${hit#*$'\t'}" == open ]]; then
    gh issue edit "${hit%%$'\t'*}" --body "$body" >/dev/null
    echo "updated #${hit%%$'\t'*}: $title"
  else
    echo "closed before, not reopened: $title"
  fi
done < <(jq -r '.[] | select(.kind == "line" or .kind == "eol") | [.title, (.body | gsub("\n"; "\\n"))] | @tsv' "$FINDINGS")

# Open line/eol issues without a finding anymore are resolved.
current="$(jq -r '.[].title' "$FINDINGS")"
while IFS=$'\t' read -r number state title; do
  [[ "$state" == open && ( "$title" == "New release line: "* || "$title" == "End of life: "* ) ]] || continue
  grep -qxF "$title" <<<"$current" && continue
  gh issue close "$number" --comment "Resolved: versions.json covers this now." >/dev/null
  echo "closed #$number: $title"
done <<<"$existing"

# Pinned versions.
body="$(jq -r --arg t "$pins_title" '.[] | select(.title == $t) | .body' "$FINDINGS")"
hit="$(lookup "$pins_title")"
number="${hit%%$'\t'*}"; state="${hit#*$'\t'}"
if [[ -z "$body" ]]; then
  if [[ "$state" == open ]]; then
    gh issue close "$number" --comment "Every pinned version is current." >/dev/null
    echo "closed #$number: $pins_title"
  fi
  exit 0
fi
if [[ -z "$hit" ]]; then
  gh issue create --title "$pins_title" --label "$label" --body "$body" >/dev/null
  echo "created: $pins_title"
  exit 0
fi
old="$(gh issue view "$number" --json body --jq .body)"
new_rows="$(comm -13 <(rows "$old") <(rows "$body"))"
if [[ "$state" != open ]]; then
  # Closed by hand: only an update it didn't list brings it back.
  [[ -n "$new_rows" ]] || { echo "closed before, nothing new: $pins_title"; exit 0; }
  gh issue reopen "$number" >/dev/null
fi
gh issue edit "$number" --body "$body" >/dev/null
echo "updated #$number: $pins_title"
if [[ -n "$new_rows" ]]; then
  { echo "New updates:"; echo; echo "| What | Pinned | Newest | Where |"; echo "|---|---|---|---|"; echo "$new_rows"; } \
    | gh issue comment "$number" --body-file - >/dev/null
  echo "commented on #$number"
fi
