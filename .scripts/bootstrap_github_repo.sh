#!/usr/bin/env bash
set -euo pipefail

OWNER="PurnaChandraPanda"
REPO="azureml-jobs-identity-tries"
REPO_DESCRIPTION="azureml job + compute identity combination validation tries"
DEFAULT_BRANCH="main"
REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"

echo "==> Checking prerequisites"
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "git not found"; exit 1; }

echo "==> Ensuring repo exists"
if gh repo view "${OWNER}/${REPO}" >/dev/null 2>&1; then
    echo "Repository ${OWNER}/${REPO} already exists - skipping creation"
else
    gh repo create "${OWNER}/${REPO}" \
        --public \
        --description "${REPO_DESCRIPTION}" \
        --disable-wiki \
        -y
    echo "Created ${OWNER}/${REPO}"
fi

SAFE_DIR="${PWD}"
if ! git config --global --get-all safe.directory | grep -Fxq "$SAFE_DIR"; then
    git config --global --add safe.directory "$SAFE_DIR"
fi

echo "==> Initializing git if needed"
if [ ! -d .git ]; then
    git init
fi

git branch -M "${DEFAULT_BRANCH}"

echo "==> Setting remote"
if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "${REMOTE_URL}"
else
    git remote add origin "${REMOTE_URL}"
fi

echo "==> Staging files"
git add .

echo "==> Committing only if there are staged changes"
if git diff --cached --quiet; then
    echo "No staged changes to commit"
else
    git commit -m "Bootstrap repository"
fi

echo "==> Pushing default branch"
git push -u origin "${DEFAULT_BRANCH}"

echo "==> Ensuring GitHub default branch is ${DEFAULT_BRANCH}"
gh api \
  --method PATCH \
  -H "Accept: application/vnd.github+json" \
  "repos/${OWNER}/${REPO}" \
  -f default_branch="${DEFAULT_BRANCH}" >/dev/null

echo "==> Protecting ${DEFAULT_BRANCH}"
gh api --method PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${OWNER}/${REPO}/branches/${DEFAULT_BRANCH}/protection" \
  --input - <<EOF
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 1,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF

echo "==> Effective protection"
gh api \
  -H "Accept: application/vnd.github+json" \
  "repos/${OWNER}/${REPO}/branches/${DEFAULT_BRANCH}/protection"

echo
echo "Done."
echo "Expected behavior:"
echo "  - Owner/admin can still push directly to ${DEFAULT_BRANCH}"
echo "  - Collaborators must use a PR with at least 1 approval"
echo "  - Force push and deletion of ${DEFAULT_BRANCH} are blocked"
