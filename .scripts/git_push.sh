#!/usr/bin/env bash
# Safer Git add/commit/push helper for one repo
# Usage:
#   ./git_push.sh "your commit message"
# Optional:
#   BRANCH=feature-x ./git_push.sh "msg"

set -euo pipefail

OWNER="PurnaChandraPanda"
REPO="azureml-jobs-identity-tries"
REMOTE_URL="https://github.com/${OWNER}/${REPO}.git"
BRANCH="${BRANCH:-main}"
MSG="${1:-}"

if [[ -z "$MSG" ]]; then
    read -rp "Commit message: " MSG
fi

# Ensure we're inside a git repo
git rev-parse --is-inside-work-tree >/dev/null 2>&1

# Show current branch
CURRENT_BRANCH="$(git branch --show-current)"
echo "Current branch: ${CURRENT_BRANCH}"

# Optional safety check: refuse if not on target branch
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    echo "ERROR: You are on '${CURRENT_BRANCH}', not '${BRANCH}'."
    echo "Checkout the correct branch first, or run with BRANCH=<name>."
    exit 1
fi

# Show status before staging
git status --short

# Stage everything (change to targeted git add if you want stricter behavior)
git add -A

# Stop if nothing is staged
if git diff --cached --quiet; then
    echo "Nothing staged to commit. Exiting cleanly."
    exit 0
fi

# Commit
git commit -m "$MSG"

# Ensure origin exists and points where expected
if git remote get-url origin >/dev/null 2>&1; then
    EXISTING_REMOTE="$(git remote get-url origin)"
    if [[ "$EXISTING_REMOTE" != "$REMOTE_URL" ]]; then
        echo "Updating origin:"
        echo "  from: $EXISTING_REMOTE"
        echo "  to  : $REMOTE_URL"
        git remote set-url origin "$REMOTE_URL"
    fi
else
    git remote add origin "$REMOTE_URL"
fi

# Refresh remote state before push
git fetch origin

# Refuse to push if local branch is behind remote
if ! git merge-base --is-ancestor "origin/${BRANCH}" HEAD 2>/dev/null; then
    echo "ERROR: Local branch is behind or diverged from origin/${BRANCH}."
    echo "Run one of the following first:"
    echo "  git pull --rebase origin ${BRANCH}"
    echo "or review the divergence manually."
    exit 1
fi

# Push and set upstream if needed
git push -u origin "$BRANCH"

echo "Push complete."
