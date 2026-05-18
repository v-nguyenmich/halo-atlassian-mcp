#!/usr/bin/env bash
# Rotate the wrapper image pins:
#   $PreviousImage := old $DefaultImage
#   $DefaultImage  := <repo>@sha256:<new-digest>
#
# Opens an auto-merging PR with the change. Idempotent: if the wrapper already
# points at the new digest, exits 0 without opening a PR.
#
# Inputs (env):
#   IMAGE          full image repo (e.g. ghcr.io/owner/halo-mcp-atlassian)
#   NEW_DIGEST     full sha256 digest of the newly promoted :stable image
#                  (e.g. sha256:abc123...)
#   GIT_REF_SHORT  short commit SHA that produced the image, used in the
#                  trailing wrapper comment (optional)
#   GH_TOKEN       token for `gh pr create`. Use a PAT (WRAPPER_BUMP_PAT)
#                  if you want CI to re-run on the bump PR.
set -euo pipefail

WRAPPER="wrapper/mcp-halo-atlassian.ps1"
[ -f "$WRAPPER" ] || { echo "::error::wrapper not found at $WRAPPER"; exit 1; }
: "${IMAGE:?IMAGE env required}"
: "${NEW_DIGEST:?NEW_DIGEST env required}"
[[ "$NEW_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "::error::NEW_DIGEST must look like sha256:<64 hex>; got '$NEW_DIGEST'"; exit 1; }

NEW_REF="${IMAGE}@${NEW_DIGEST}"

# Use a single Python helper for everything regex-y: extract old value AND
# rewrite. Bash regex differs across platforms; Python is portable.
python3 - "$WRAPPER" "$NEW_REF" "${GIT_REF_SHORT:-${GITHUB_SHA:0:7}}" > /tmp/old_default <<'PY'
import re, sys, pathlib
path, new_ref, short = sys.argv[1:]
text = pathlib.Path(path).read_text(encoding="utf-8")

m = re.search(r"^\$DefaultImage\s*=\s*'([^']+)'", text, re.MULTILINE)
if not m:
    print("ERROR: could not parse $DefaultImage", file=sys.stderr); sys.exit(1)
old_default = m.group(1)
print(old_default)

if old_default == new_ref:
    sys.exit(2)  # special: no change needed

text, n_def = re.subn(
    r"^(\$DefaultImage\s*=\s*')[^']+(')(\s*#[^\r\n]*)?",
    lambda mo: f"{mo.group(1)}{new_ref}{mo.group(2)}  # auto-bumped from {short}",
    text, count=1, flags=re.MULTILINE,
)
if n_def != 1:
    print("ERROR: failed to rewrite $DefaultImage line", file=sys.stderr); sys.exit(1)

text, n_prev = re.subn(
    r"^(\$PreviousImage\s*=\s*\$env:HALO_MCP_PREV_IMAGE\s*;\s*if\s*\(-not\s*\$PreviousImage\)\s*\{\s*\$PreviousImage\s*=\s*')[^']+(')",
    lambda mo: f"{mo.group(1)}{old_default}{mo.group(2)}",
    text, count=1, flags=re.MULTILINE,
)
if n_prev != 1:
    print("ERROR: failed to rewrite $PreviousImage line", file=sys.stderr); sys.exit(1)

pathlib.Path(path).write_text(text, encoding="utf-8")
PY
rc=$?
case $rc in
    0) old_default=$(cat /tmp/old_default | head -n1) ;;
    2) echo "wrapper already pinned to $NEW_REF; nothing to do."; exit 0 ;;
    *) echo "::error::python rewrite failed (rc=$rc)"; exit 1 ;;
esac

if git diff --quiet -- "$WRAPPER"; then
    echo "no change after rewrite; bailing."
    exit 0
fi

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

branch="auto-bump/wrapper-${NEW_DIGEST#sha256:}"
branch="${branch:0:60}"

git fetch origin "$branch" 2>/dev/null && git push origin --delete "$branch" 2>/dev/null || true

git checkout -b "$branch"
git add "$WRAPPER"
git commit -m "chore(wrapper): bump pinned image to ${NEW_DIGEST:0:19}

Promoted to :stable by CI run ${GITHUB_RUN_ID:-unknown}.
Old default -> \$PreviousImage: $old_default
New default:                    $NEW_REF

This commit was opened automatically by .github/workflows/ci.yml
(scripts/bump-wrapper-digest.sh).

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push -u origin "$branch"

if pr_url=$(gh pr create \
        --title "chore(wrapper): bump pinned image to ${NEW_DIGEST:0:19}" \
        --body "Auto-bump from CI run [${GITHUB_RUN_ID:-unknown}](${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-})

\`\`\`
old \$DefaultImage:  $old_default
new \$DefaultImage:  $NEW_REF
\`\`\`

If \`automerge.yml\` is wired up (and CI runs on this PR), it will merge itself once green." \
        --base main --head "$branch" 2>/dev/null); then
    echo "opened: $pr_url"
    gh pr merge --auto --squash "$pr_url" || true
else
    echo "PR already exists for $branch; enabling auto-merge."
    pr_url=$(gh pr list --head "$branch" --json url --jq '.[0].url')
    [ -n "$pr_url" ] && gh pr merge --auto --squash "$pr_url" || true
fi
