#!/usr/bin/env bash
#
# Sync upstream changes onto the `custom` branch.
#
# This fork carries Coolify-specific docker-compose.yml customisations on top of
# an upstream Langfuse release tag. Syncing = rebasing those customisations onto
# a newer upstream tag, then re-pointing the sha-based image tags.
#
# SAFETY RULES ENCODED HERE (learned the hard way — see SYNC-UPSTREAM.md):
#   1. Never cross a major version implicitly. The default target is the highest
#      tag within the major line the branch is CURRENTLY on. Crossing a major
#      requires --allow-major (or an explicit --tag).
#   2. Never rebase onto a tag whose container images were never published.
#      Upstream tags git releases that never get a Docker build (v3.225.3 is the
#      canonical example). Both langfuse/langfuse and langfuse/langfuse-worker
#      are checked before anything is rewritten.
#   3. Never rebase onto an image that lacks linux/arm64. The production host
#      (apps.coriou.net) is Hetzner ARM; an amd64-only image will not run at all.
#   4. Safe to run non-interactively (--yes), and it says what it will do before
#      it does it (--dry-run shows the whole plan and changes nothing).
#
# Usage: ./sync-upstream.sh [options]   (see --help)

set -euo pipefail

# ---------------------------------------------------------------- configuration

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
WORK_BRANCH="${WORK_BRANCH:-custom}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
REQUIRED_PLATFORM="${REQUIRED_PLATFORM:-linux/arm64}"
IMAGE_REPOS=("langfuse/langfuse" "langfuse/langfuse-worker")

SYNC_TARGET="tag"      # tag | main
EXPLICIT_TAG=""
ALLOW_MAJOR=false
ASSUME_YES=false
DRY_RUN=false
SKIP_IMAGE_CHECK=false

STASHED=false

# ---------------------------------------------------------------------- helpers

die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "$*"; }

usage() {
    cat <<'EOF'
Sync upstream Langfuse changes onto the custom branch.

Usage: ./sync-upstream.sh [options]

Target selection (default: highest tag in the CURRENT major line):
  --tag vX.Y.Z        Rebase onto this exact upstream tag. Implies you have
                      chosen deliberately, so it may cross a major version.
  --main              Rebase onto upstream/main instead of a release tag.
                      Requires --allow-major if it crosses a major version.
  --allow-major       Permit crossing to a higher major version. Without this,
                      the script refuses and tells you what it skipped.

Execution:
  --yes, -y           Assume "yes" for every prompt (non-interactive / CI).
  --non-interactive   Alias for --yes.
  --dry-run           Print the full plan and exit without changing anything.
  --skip-image-check  Skip the registry preflight. ESCAPE HATCH ONLY — this is
                      the check that prevents rebasing onto an unbuildable tag.
  -h, --help          Show this help.

Environment overrides:
  UPSTREAM_REMOTE (default: upstream)   WORK_BRANCH (default: custom)
  COMPOSE_FILE (default: docker-compose.yml)
  REQUIRED_PLATFORM (default: linux/arm64)

Examples:
  ./sync-upstream.sh                      # safe default, interactive
  ./sync-upstream.sh --dry-run            # show the plan, change nothing
  ./sync-upstream.sh --yes                # unattended, still refuses majors
  ./sync-upstream.sh --tag v3.225.2 --yes # pin an exact tag
  ./sync-upstream.sh --allow-major --yes  # deliberately move to v4.x
EOF
}

confirm() {
    # confirm "<prompt>" -> 0 = proceed, 1 = declined
    local prompt="$1"
    if [ "$ASSUME_YES" = true ]; then
        info "✅ ${prompt} (auto-yes)"
        return 0
    fi
    local reply
    read -r -p "${prompt} (y/n) " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]]
}

# In-place sed that works on both GNU (Linux) and BSD (macOS) sed.
# The original script hardcoded `sed -i ''`, which is a syntax error on Linux.
sed_inplace() {
    local expr="$1" file="$2"
    if sed --version >/dev/null 2>&1; then
        sed -i -e "$expr" "$file"          # GNU
    else
        sed -i '' -e "$expr" "$file"       # BSD / macOS
    fi
}

major_of() {
    # major_of v3.225.2 -> 3
    printf '%s' "${1#v}" | cut -d. -f1
}

# --------------------------------------------------------- registry preflight

registry_token() {
    curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$1:pull" \
        | jq -r '.token'
}

# platforms_for <repo> <tag>
# Prints "os/arch" lines on success. Returns 1 if the manifest does not exist,
# 2 if it exists but the platform list could not be determined.
platforms_for() {
    local repo="$1" tag="$2" token code body
    token="$(registry_token "$repo")" || return 2
    body="$(mktemp)"
    code="$(curl -s -o "$body" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}")"

    if [ "$code" != "200" ]; then
        rm -f "$body"
        return 1
    fi

    local plats
    plats="$(jq -r '[.manifests[]? | select(.platform.os != "unknown")
                    | "\(.platform.os)/\(.platform.architecture)"] | unique | .[]' "$body" 2>/dev/null)"
    rm -f "$body"

    if [ -z "$plats" ]; then
        return 2
    fi
    printf '%s\n' "$plats"
}

# check_images <short-sha> -> 0 if every repo has the tag AND the required platform
check_images() {
    local sha="$1"
    local tag="sha-${sha}"
    local ok=true repo plats rc
    for repo in "${IMAGE_REPOS[@]}"; do
        set +e
        plats="$(platforms_for "$repo" "$tag")"
        rc=$?
        set -e
        case "$rc" in
            1)
                echo "   ❌ ${repo}:${tag} — NOT PUBLISHED (registry 404)"
                ok=false
                ;;
            2)
                echo "   ❌ ${repo}:${tag} — exists but platform list undeterminable"
                ok=false
                ;;
            0)
                if printf '%s\n' "$plats" | grep -qx "$REQUIRED_PLATFORM"; then
                    echo "   ✅ ${repo}:${tag} — $(printf '%s' "$plats" | tr '\n' ' ')"
                else
                    echo "   ❌ ${repo}:${tag} — missing ${REQUIRED_PLATFORM} (has: $(printf '%s' "$plats" | tr '\n' ' '))"
                    ok=false
                fi
                ;;
        esac
    done
    [ "$ok" = true ]
}

# ------------------------------------------------------------- argument parsing

while [ $# -gt 0 ]; do
    case "$1" in
        --main)             SYNC_TARGET="main" ;;
        --tag)              [ $# -ge 2 ] || die "--tag requires a value (e.g. --tag v3.225.2)"
                            EXPLICIT_TAG="$2"; SYNC_TARGET="tag"; shift ;;
        --tag=*)            EXPLICIT_TAG="${1#*=}"; SYNC_TARGET="tag" ;;
        --allow-major)      ALLOW_MAJOR=true ;;
        -y|--yes|--non-interactive) ASSUME_YES=true ;;
        --dry-run)          DRY_RUN=true ;;
        --skip-image-check) SKIP_IMAGE_CHECK=true ;;
        -h|--help)          usage; exit 0 ;;
        *)                  usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
done

if [ -n "$EXPLICIT_TAG" ] && [[ ! "$EXPLICIT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "--tag must look like vX.Y.Z (got: ${EXPLICIT_TAG})"
fi

for tool in git curl jq; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: ${tool}"
done

echo "🔄 Syncing with upstream..."
[ "$DRY_RUN" = true ] && echo "🧪 DRY RUN — nothing will be modified."

# ------------------------------------------------------------ repo preconditions

git rev-parse --git-dir >/dev/null 2>&1 || die "Not inside a git repository."
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
    || die "No '${UPSTREAM_REMOTE}' remote. Add it: git remote add ${UPSTREAM_REMOTE} https://github.com/langfuse/langfuse.git"
[ -f "$COMPOSE_FILE" ] || die "Compose file not found: ${COMPOSE_FILE}"

# Deal with a dirty tree BEFORE any branch switch — otherwise `git checkout`
# refuses and the script dies half-way through its preconditions.
if [ -n "$(git status --porcelain)" ]; then
    echo "⚠️  You have uncommitted changes:"
    git status --short
    if [ "$DRY_RUN" = true ]; then
        echo "   (dry run: would offer to stash these)"
    elif confirm "Stash them?"; then
        git stash push -m "Auto-stash before sync at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        STASHED=true
    else
        die "Please commit or stash your changes before syncing."
    fi
fi

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$WORK_BRANCH" ]; then
    echo "⚠️  You're not on the '${WORK_BRANCH}' branch (currently on: ${CURRENT_BRANCH})"
    if [ "$DRY_RUN" = true ]; then
        echo "   (dry run: would switch to '${WORK_BRANCH}')"
    elif confirm "Switch to '${WORK_BRANCH}' branch?"; then
        git checkout "$WORK_BRANCH"
        CURRENT_BRANCH="$WORK_BRANCH"
    else
        die "Aborted. Please switch to '${WORK_BRANCH}' manually."
    fi
fi

echo "📥 Fetching from ${UPSTREAM_REMOTE}..."
git fetch "$UPSTREAM_REMOTE"
git fetch "$UPSTREAM_REMOTE" --tags

# ------------------------------------------------------------- target resolution

CURRENT_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "$CURRENT_TAG" ]; then
    CURRENT_MAJOR="$(major_of "$CURRENT_TAG")"
    echo "📍 Branch is currently based on upstream ${CURRENT_TAG} (major line: v${CURRENT_MAJOR})"
else
    CURRENT_MAJOR=""
    echo "📍 Could not determine the current upstream base tag."
fi

LATEST_OVERALL="$(git tag -l | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)"

if [ "$SYNC_TARGET" = "main" ]; then
    TARGET="${UPSTREAM_REMOTE}/main"
    TARGET_SHA="$(git rev-parse --short=7 "$TARGET")"
    MAIN_DESC="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' "$TARGET" 2>/dev/null || true)"
    if [ -n "$MAIN_DESC" ] && [ -n "$CURRENT_MAJOR" ]; then
        TARGET_MAJOR="$(major_of "$MAIN_DESC")"
        if [ "$TARGET_MAJOR" != "$CURRENT_MAJOR" ] && [ "$ALLOW_MAJOR" != true ]; then
            die "${TARGET} is on major v${TARGET_MAJOR}, but this branch is on v${CURRENT_MAJOR}.
   Crossing a major version is never implicit. Re-run with --allow-major if you
   genuinely intend to move this production deployment to v${TARGET_MAJOR}."
        fi
    fi
    echo "📌 Target: ${TARGET} (commit ${TARGET_SHA})"

elif [ -n "$EXPLICIT_TAG" ]; then
    git rev-parse -q --verify "refs/tags/${EXPLICIT_TAG}" >/dev/null \
        || die "Tag ${EXPLICIT_TAG} does not exist upstream."
    TARGET="$EXPLICIT_TAG"
    TARGET_SHA="$(git rev-list -n 1 "$TARGET" | cut -c1-7)"
    if [ -n "$CURRENT_MAJOR" ] && [ "$(major_of "$TARGET")" != "$CURRENT_MAJOR" ]; then
        echo "⚠️  ${TARGET} crosses from major v${CURRENT_MAJOR} to v$(major_of "$TARGET") — explicit --tag, so allowed."
    fi
    echo "📌 Target: ${TARGET} (explicitly requested, commit ${TARGET_SHA})"

else
    # Default: highest tag WITHIN the current major line.
    if [ -z "$CURRENT_MAJOR" ]; then
        die "Cannot determine the current major line, so cannot pick a safe default target.
   Pass an explicit --tag vX.Y.Z."
    fi
    TARGET="$(git tag -l | grep -E "^v${CURRENT_MAJOR}\.[0-9]+\.[0-9]+$" | sort -V | tail -1)"
    [ -n "$TARGET" ] || die "No tags found in the v${CURRENT_MAJOR} line."
    TARGET_SHA="$(git rev-list -n 1 "$TARGET" | cut -c1-7)"
    echo "🏷️  Target: ${TARGET} — highest tag in the current v${CURRENT_MAJOR} line (commit ${TARGET_SHA})"
    if [ -n "$LATEST_OVERALL" ] && [ "$(major_of "$LATEST_OVERALL")" != "$CURRENT_MAJOR" ]; then
        echo "ℹ️  Upstream's newest release is ${LATEST_OVERALL}, deliberately NOT chosen:"
        echo "    crossing a major version requires --allow-major or --tag ${LATEST_OVERALL}."
    fi
fi

if [ "$TARGET_SHA" = "$(git rev-parse --short=7 HEAD)" ] || \
   { [ "$SYNC_TARGET" = "tag" ] && [ -n "$CURRENT_TAG" ] && [ "$TARGET" = "$CURRENT_TAG" ]; }; then
    echo "✅ Already based on ${TARGET} — nothing to sync."
    exit 0
fi

# ------------------------------------------------------------- image preflight

USES_SHA_TAGS=false
grep -q "langfuse.*:sha-" "$COMPOSE_FILE" && USES_SHA_TAGS=true

if [ "$USES_SHA_TAGS" = true ]; then
    echo ""
    echo "🔍 Registry preflight for sha-${TARGET_SHA} (need ${REQUIRED_PLATFORM}):"
    if [ "$SKIP_IMAGE_CHECK" = true ]; then
        echo "   ⏭️  SKIPPED via --skip-image-check. You are on your own."
    elif ! check_images "$TARGET_SHA"; then
        echo ""
        echo "🔎 Looking for the newest usable tag in the v$(major_of "$TARGET") line..."
        SUGGESTION=""
        while read -r cand; do
            [ -n "$cand" ] || continue
            cand_sha="$(git rev-list -n 1 "$cand" | cut -c1-7)"
            if check_images "$cand_sha" >/dev/null 2>&1; then
                SUGGESTION="$cand"
                break
            fi
        done < <(git tag -l | grep -E "^v$(major_of "$TARGET")\.[0-9]+\.[0-9]+$" | sort -Vr | awk 'NR<=20')

        echo ""
        if [ -n "$SUGGESTION" ] && [ "$SUGGESTION" = "$CURRENT_TAG" ]; then
            echo "✅ ${TARGET} has no published container images, and ${SUGGESTION} — the newest"
            echo "   tag in the v$(major_of "$TARGET") line that IS published for ${REQUIRED_PLATFORM} — is the one"
            echo "   this branch is already based on. You are up to date; nothing to do."
            exit 0
        fi
        echo "❌ ${TARGET} has no usable container images. Upstream tags releases in git"
        echo "   that never get a Docker build — rebasing onto one would leave this"
        echo "   deployment unable to pull an image. Nothing has been changed."
        if [ -n "$SUGGESTION" ]; then
            echo ""
            echo "   👉 Newest tag in this line that IS published for ${REQUIRED_PLATFORM}: ${SUGGESTION}"
            echo "      Re-run with: ./sync-upstream.sh --tag ${SUGGESTION}"
        fi
        exit 1
    fi
fi

# --------------------------------------------------------------------- the plan

echo ""
echo "📊 Plan:"
echo "   branch          : ${CURRENT_BRANCH}"
echo "   current base    : ${CURRENT_TAG:-unknown}"
echo "   rebase onto     : ${TARGET} (${TARGET_SHA})"
if [ "$USES_SHA_TAGS" = true ]; then
    # sed -n '1s//p' consumes all input, so no SIGPIPE under `set -o pipefail`.
    CURRENT_IMG_TAG="$(grep -oE 'langfuse/langfuse(-worker)?:sha-[a-f0-9]+' "$COMPOSE_FILE" | sed -n '1s/.*://p')"
    echo "   image tags      : sha-${CURRENT_IMG_TAG#sha-} → sha-${TARGET_SHA}"
else
    echo "   image tags      : no sha- tags in ${COMPOSE_FILE}, nothing to re-point"
fi
echo ""
echo "📜 Upstream commits you'd pick up (first 20):"
git --no-pager log --oneline -n 20 "HEAD..${TARGET}"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "🧪 Dry run complete. No changes made."
    exit 0
fi

confirm "Rebase ${CURRENT_BRANCH} onto ${TARGET}?" || { echo "❌ Sync cancelled."; exit 0; }

# ------------------------------------------------------------------- the rebase

echo "🔨 Rebasing ${CURRENT_BRANCH} onto ${TARGET}..."
if ! git rebase "$TARGET"; then
    cat <<EOF
⚠️  Rebase encountered conflicts.
Resolve them, then run:
   git add <resolved-files>
   git rebase --continue

Or abort with:
   git rebase --abort
EOF
    [ "$STASHED" = true ] && echo "💾 Note: your pre-sync stash is still saved (git stash list)."
    exit 1
fi

echo "✅ Rebase successful!"

if [ "$USES_SHA_TAGS" = true ]; then
    echo "🔖 Updating image tags to sha-${TARGET_SHA}..."
    sed_inplace "s|langfuse/langfuse-worker:sha-[a-f0-9]*|langfuse/langfuse-worker:sha-${TARGET_SHA}|g" "$COMPOSE_FILE"
    sed_inplace "s|langfuse/langfuse:sha-[a-f0-9]*|langfuse/langfuse:sha-${TARGET_SHA}|g" "$COMPOSE_FILE"

    if [ -n "$(git status --porcelain -- "$COMPOSE_FILE")" ]; then
        git add "$COMPOSE_FILE"
        git commit -m "chore: update Docker image tags to sha-${TARGET_SHA} for ${TARGET}"
        echo "✅ Image tags updated and committed"
    else
        echo "ℹ️  Image tags already at sha-${TARGET_SHA}, nothing to commit."
    fi
fi

echo ""
echo "📝 Your Coolify docker-compose customisations have been preserved."
echo "🔍 Diff from ${TARGET}:"
git --no-pager diff "$TARGET" --stat -- 'docker-compose*.yml' 'clickhouse-config-d/*' || true

if [ "$STASHED" = true ]; then
    echo ""
    if confirm "Restore your stashed changes?"; then
        git stash pop
    else
        echo "💾 Your changes are stashed. Restore later with: git stash pop"
    fi
fi

cat <<EOF

🎉 Sync complete.

Next steps (this fork uses a rebase workflow, so the push MUST be forced):
   git push origin ${WORK_BRANCH} --force-with-lease

Before you push, consider tagging the current remote state as a rollback point:
   git tag ${WORK_BRANCH}-pre-${TARGET}-\$(date -u +%Y%m%d) origin/${WORK_BRANCH}
   git push origin ${WORK_BRANCH}-pre-${TARGET}-\$(date -u +%Y%m%d)
EOF
