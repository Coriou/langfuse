#!/bin/bash

# Sync upstream changes to the custom branch
# This script helps keep your fork in sync with the upstream repository
# while preserving your Docker Compose modifications for Coolify

set -e

echo "🔄 Syncing with upstream..."

# Ensure we're on the custom branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "custom" ]; then
    echo "⚠️  Warning: You're not on the 'custom' branch (currently on: $CURRENT_BRANCH)"
    read -p "Do you want to switch to 'custom' branch? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git checkout custom
    else
        echo "❌ Aborted. Please switch to 'custom' branch manually."
        exit 1
    fi
fi

# Check for uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  You have uncommitted changes:"
    git status --short
    read -p "Do you want to stash them? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git stash push -m "Auto-stash before sync at $(date)"
        STASHED=true
    else
        echo "❌ Please commit or stash your changes before syncing."
        exit 1
    fi
fi

# Fetch latest changes from upstream
echo "📥 Fetching from upstream..."
git fetch upstream

# Show what will change
echo ""
echo "📊 Changes between your branch and upstream/main:"
git log --oneline --graph HEAD..upstream/main | head -20
echo ""

read -p "Do you want to rebase on upstream/main? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Sync cancelled."
    exit 0
fi

# Rebase onto upstream/main
echo "🔨 Rebasing custom branch on upstream/main..."
if git rebase upstream/main; then
    echo "✅ Rebase successful!"
    echo ""
    echo "📝 Your Docker Compose changes for Coolify have been preserved."
    echo ""
    echo "🔍 Verifying changes..."
    echo "Current diff from upstream/main:"
    git diff upstream/main --stat docker-compose*.yml
    echo ""
    echo "✨ To push these changes to your fork, run:"
    echo "   git push origin custom --force-with-lease"
else
    echo "⚠️  Rebase encountered conflicts."
    echo "Please resolve them manually, then run:"
    echo "   git add <resolved-files>"
    echo "   git rebase --continue"
    echo ""
    echo "Or abort the rebase with:"
    echo "   git rebase --abort"
    exit 1
fi

# Restore stashed changes if any
if [ "$STASHED" = true ]; then
    echo ""
    read -p "Do you want to restore your stashed changes? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git stash pop
    else
        echo "💾 Your changes are stashed. Restore them later with: git stash pop"
    fi
fi

echo ""
echo "🎉 Sync complete!"
