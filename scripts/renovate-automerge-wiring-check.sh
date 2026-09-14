#!/usr/bin/env bash
# Wiring assertion for the Renovate/MergeRaptor auto-merge path (issue #403).
#
# Asserts the declarative facts that make a real mergeraptor PR mergeable, and
# reports the live state that would trigger an end-to-end merge. Exits non-zero
# on any failed assertion so a scheduled run fails loudly when the wiring drifts.
#
# Env:
#   OWNER / REPO - target repo (default projectbluefin/actions)
#   GH_TOKEN     - token with repo read (github.token in CI)
#
# gh is invoked as a command so it can be mocked in tests.

set -euo pipefail

OWNER="${OWNER:-projectbluefin}"
REPO="${REPO:-actions}"
REPO_REF="$OWNER/$REPO"

fail=0
note() { printf '%s\n' "$*"; }
fail_assert() { echo "FAIL: $*"; fail=1; }

# 1. The repo must allow auto-merge. Without this, GitHub ignores the
#    renovate `automerge` setting regardless of config.
note "== allow_auto_merge =="
allow_auto_merge=$(gh api "repos/$REPO_REF" --jq '.allow_auto_merge // false')
note "allow_auto_merge = $allow_auto_merge"
[ "$allow_auto_merge" = "true" ] || \
  fail_assert "repo allow_auto_merge is not true; GitHub ignores automerge regardless of config"

# 2. The MergeRaptor app must be the SOLE review-bypass actor on main. The
#    minted app token can only bypass the required review if this app is in the
#    allowance; anything else (a user/team bypass, or none) means the merge
#    fails at the last step. The repo uses branch rulesets, so read bypass
#    actors from the active branch ruleset rather than the legacy protection API.
note "== main branch-protection bypass actors =="
ruleset_resp=$(gh api "repos/$REPO_REF/rulesets" 2>/dev/null || echo "null")
main_ruleset="null"

if jq -e 'type == "object" and .target == "branch"' <<<"$ruleset_resp" >/dev/null 2>&1; then
  main_ruleset="$ruleset_resp"
elif jq -e 'type == "array"' <<<"$ruleset_resp" >/dev/null 2>&1; then
  for rs_id in $(jq -r '.[] | select(.target == "branch" and .enforcement == "active") | .id' <<<"$ruleset_resp"); do
    detailed=$(gh api "repos/$REPO_REF/rulesets/$rs_id" 2>/dev/null || true)
    if [ -n "$detailed" ] && jq -e '((.conditions.ref_name.include // []) | index("refs/heads/main")) or ((.conditions.ref_name.include // []) | index("main"))' <<<"$detailed" >/dev/null 2>&1; then
      main_ruleset="$detailed"
      break
    fi
  done
fi

if [ -z "$main_ruleset" ] || [ "$main_ruleset" = "null" ]; then
  fail_assert "no branch ruleset enforces main"
  bypass='[]'
else
  bypass=$(echo "$main_ruleset" | jq -c '.bypass_actors // []')
fi
note "bypass_actors = $bypass"
n_mergeraptor=$(echo "$bypass" \
  | jq '[.[] | select((.actor_type == "app" or .actor_type == "Integration") and (((.actor_name // "") | ascii_downcase) == "mergeraptor" or .actor_id == 3069633))] | length')
n_other=$(echo "$bypass" \
  | jq '[.[] | select(.actor_type != "OrganizationAdmin") | select((.actor_type != "app" and .actor_type != "Integration") or ((((.actor_name // "") | ascii_downcase) != "mergeraptor") and .actor_id != 3069633))] | length')
[ "$n_mergeraptor" -eq 1 ] || \
  fail_assert "mergeraptor app is not exactly one bypass actor on main"
[ "$n_other" -eq 0 ] || \
  fail_assert "non-mergeraptor bypass actor(s) present on main: $bypass"

# 3. Informational: live mergeraptor/renovate PRs with auto-merge enabled. These
#    are exactly the PRs the auto-merge workflow (renovate-automerge.yml) would
#    pick up. None here is expected when Renovate has nothing to bump.
note "== live mergeraptor/renovate PRs with auto-merge enabled =="
gh api graphql \
  -f owner="$OWNER" -f repo="$REPO" \
  -f query='
    query($owner: String!, $repo: String!) {
      repository(owner: $owner, name: $repo) {
        pullRequests(first: 20, states: OPEN, baseRefName: "main") {
          nodes {
            number
            author { login }
            autoMergeRequest { enabledAt }
          }
        }
      }
    }' \
  --jq '
    .data.repository.pullRequests.nodes
    | map(
        . as $n
        | ($n.author.login | ascii_downcase | sub("^app/"; "") | sub("\\[bot\\]$"; "")) as $login
        | select(($login == "mergeraptor" or $login == "renovate") and $n.autoMergeRequest != null)
        | "  #\($n.number) \($n.author.login) autoMerge=\($n.autoMergeRequest.enabledAt // "null")"
      )
    | (if length == 0 then ["  (none)"] else . end)
    | .[]'

if [ "$fail" -ne 0 ]; then
  echo "Auto-merge wiring check: FAILED (see above)."
  exit 1
fi
echo "Auto-merge wiring check: OK"
