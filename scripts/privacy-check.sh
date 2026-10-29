#!/bin/bash
# Fails if the repository contains things that must never be published: credentials, e-mail addresses, home paths,
# account/organization ids. Prints file:line and the kind of match, never the matched text.
#   ./scripts/privacy-check.sh            working tree (tracked files)
#   ./scripts/privacy-check.sh --history  also every commit
# Extra personal terms (names, project names…) can go one regex per line in a git-ignored file `.privacy-terms`.
set -uo pipefail
cd "$(dirname "$0")/.."
SELF="scripts/privacy-check.sh"
fail=0

scan() {  # $1 = label, $2 = regex, $3 = optional allow regex, $4... = revisions ("" = working tree)
  local label="$1" re="$2" allow="${3:-}"; shift 3
  for rev in "$@"; do
    local hits
    if [ -z "$rev" ]; then hits=$(git grep -I -n -E "$re" -- . ":!$SELF" 2>/dev/null | cut -d: -f1,2)
    else hits=$(git grep -I -n -E "$re" "$rev" -- . ":!$SELF" 2>/dev/null | cut -d: -f1-3 | sed "s/^$rev:/${rev:0:7}:/"); fi
    if [ -n "$allow" ] && [ -n "$hits" ]; then
      # re-check each hit line against the allow-list without printing it
      local kept=""
      while IFS= read -r h; do
        local f l; f=$(echo "$h" | awk -F: '{print $(NF-1)}'); l=$(echo "$h" | awk -F: '{print $NF}')
        if [ -z "$rev" ]; then line=$(sed -n "${l}p" "$f"); else line=$(git show "$rev:$f" | sed -n "${l}p"); fi
        echo "$line" | grep -o -E "$re" | grep -v -E "$allow" -q && kept+="$h"$'\n'
      done <<< "$hits"
      hits="$kept"
    fi
    if [ -n "$hits" ]; then echo "$label:"; echo "$hits" | sed '/^$/d;s/^/  /'; fail=1; fi
  done
}

revs=("")
if [ "${1:-}" = "--history" ]; then revs=("" $(git rev-list --all)); fi

scan "secret-like string" 'sk-ant|Bearer [A-Za-z0-9]|sessionKey|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{12}|BEGIN (RSA|OPENSSH|EC) PRIVATE' "" "${revs[@]}"
scan "e-mail address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' 'noreply@anthropic\.com|users\.noreply\.github\.com|@example\.|^user@claude\.ai$' "${revs[@]}"
scan "home directory path" '/Users/[A-Za-z0-9._-]+' '/Users/(x|demo|you|name)$' "${revs[@]}"
scan "organization id in URL" 'organizations/[0-9a-f]{8}-[0-9a-f]{4}' '^organizations/00000000-0000$' "${revs[@]}"
scan "UUID (only the all-zero example id is allowed)" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' '^00000000-0000-4000-8000-000000000000$' "${revs[@]}"
if [ -f .privacy-terms ]; then
  while IFS= read -r term; do [ -n "$term" ] && scan "personal term" "$term" "" "${revs[@]}"; done < .privacy-terms
fi
# files that must stay out of the repository
for f in $(git ls-files); do
  case "$f" in docs/samples/private/*|*state.json|*debug.log|*.sqlite|*usage-url.txt|*credits-url.txt|*schedules.json) echo "forbidden file tracked: $f"; fail=1;; esac
done

[ "$fail" = 0 ] && echo "privacy-check: clean" || { echo "privacy-check: FAILED"; exit 1; }
