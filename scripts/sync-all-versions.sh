#!/usr/bin/env bash
#
# WordPress All Versions Sync Script
# Fetches all WordPress version tags from GitHub and creates corresponding releases.
#
# Usage:
#   ./scripts/sync-all-versions.sh [options]
#
# Options:
#   --min-version X.Y       Only sync versions >= X.Y (default: 5.0)
#   --max-version X.Y       Only sync versions <= X.Y (default: latest)
#   --single X.Y.Z          Sync only a single specific version
#   --include-prerelease    Include alpha, beta, and RC versions
#   --dry-run               Show what would be done without making changes
#   --push                  Push branches and tags to remote
#
# Examples:
#   ./scripts/sync-all-versions.sh --min-version 6.0
#   ./scripts/sync-all-versions.sh --single 6.4.3 --push
#   ./scripts/sync-all-versions.sh --include-prerelease --min-version 6.5
#   ./scripts/sync-all-versions.sh --dry-run
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_version() {
    echo -e "${CYAN}[VERSION]${NC} $1"
}

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --min-version X.Y       Only sync versions >= X.Y (default: 5.0)"
    echo "  --max-version X.Y       Only sync versions <= X.Y (default: latest)"
    echo "  --single X.Y.Z          Sync only a single specific version"
    echo "  --include-prerelease    Include alpha, beta, and RC versions"
    echo "  --dry-run               Show what would be done without making changes"
    echo "  --push                  Push branches and tags to remote"
    echo ""
    echo "Creates a branch per major.minor version (e.g., 6.4.x, 6.5.x)"
    echo ""
    echo "Examples:"
    echo "  $0 --min-version 6.0"
    echo "  $0 --single 6.4.3 --push"
    echo "  $0 --include-prerelease --min-version 6.5"
    echo "  $0 --dry-run"
    exit 1
}

# Default options
MIN_VERSION="5.0"
MAX_VERSION=""
SINGLE_VERSION=""
DRY_RUN=false
DO_PUSH=false
INCLUDE_PRERELEASE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --min-version)
            MIN_VERSION="$2"
            shift 2
            ;;
        --max-version)
            MAX_VERSION="$2"
            shift 2
            ;;
        --single)
            SINGLE_VERSION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --push)
            DO_PUSH=true
            shift
            ;;
        --include-prerelease)
            INCLUDE_PRERELEASE=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Function to compare versions
version_ge() {
    # Returns 0 if $1 >= $2
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

version_le() {
    # Returns 0 if $1 <= $2
    printf '%s\n%s\n' "$1" "$2" | sort -V -C
}

# Function to get major.minor from version (handles 6.5, 6.5.1, 6.5-beta1)
get_major_minor() {
    echo "$1" | grep -oE '^[0-9]+\.[0-9]+'
}

# Function to get branch name for a version
get_branch_name() {
    echo "$(get_major_minor "$1").x"
}

# Fetch all WordPress version tags from GitHub
log_step "Fetching WordPress version tags from GitHub..."

# Use GitHub API to get all tags
TAGS_JSON=$(curl -sL "https://api.github.com/repos/WordPress/WordPress/tags?per_page=100")

# Extract version numbers (filter out non-version tags)
# Matches: 6.5, 6.5.1, 6.5-beta1, 6.5-RC1, 6.5-alpha1
ALL_VERSIONS=$(echo "$TAGS_JSON" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+((\.[0-9]+)|(-(alpha|beta|RC)[0-9]+))?$' | sort -V)

# If we need more than 100 tags, paginate
PAGE=2
while true; do
    NEXT_JSON=$(curl -sL "https://api.github.com/repos/WordPress/WordPress/tags?per_page=100&page=$PAGE")
    NEXT_VERSIONS=$(echo "$NEXT_JSON" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+((\.[0-9]+)|(-(alpha|beta|RC)[0-9]+))?$' 2>/dev/null || true)

    if [[ -z "$NEXT_VERSIONS" ]]; then
        break
    fi

    ALL_VERSIONS=$(printf '%s\n%s' "$ALL_VERSIONS" "$NEXT_VERSIONS" | sort -V)
    PAGE=$((PAGE + 1))

    # Safety limit
    if [[ $PAGE -gt 10 ]]; then
        break
    fi
done

# Remove duplicates and sort
ALL_VERSIONS=$(echo "$ALL_VERSIONS" | sort -V | uniq)

# Filter out pre-release versions unless --include-prerelease is set
if [[ "$INCLUDE_PRERELEASE" == false ]]; then
    STABLE_VERSIONS=$(echo "$ALL_VERSIONS" | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' || true)
    PRERELEASE_COUNT=$(($(echo "$ALL_VERSIONS" | wc -l) - $(echo "$STABLE_VERSIONS" | grep -v '^$' | wc -l)))
    ALL_VERSIONS="$STABLE_VERSIONS"
    if [[ $PRERELEASE_COUNT -gt 0 ]]; then
        log_info "Skipping $PRERELEASE_COUNT pre-release versions (use --include-prerelease to include)"
    fi
fi

log_info "Found $(echo "$ALL_VERSIONS" | grep -v '^$' | wc -l | tr -d ' ') WordPress versions"

# Filter versions based on options
VERSIONS_TO_SYNC=""

if [[ -n "$SINGLE_VERSION" ]]; then
    # Single version mode
    if echo "$ALL_VERSIONS" | grep -q "^${SINGLE_VERSION}$"; then
        VERSIONS_TO_SYNC="$SINGLE_VERSION"
    else
        log_error "Version $SINGLE_VERSION not found in WordPress releases"
        exit 1
    fi
else
    # Filter by min/max version
    for version in $ALL_VERSIONS; do
        # Check min version
        if ! version_ge "$version" "$MIN_VERSION"; then
            continue
        fi

        # Check max version
        if [[ -n "$MAX_VERSION" ]] && ! version_le "$version" "$MAX_VERSION"; then
            continue
        fi

        VERSIONS_TO_SYNC="$VERSIONS_TO_SYNC $version"
    done
fi

VERSIONS_TO_SYNC=$(echo "$VERSIONS_TO_SYNC" | tr ' ' '\n' | grep -v '^$' | sort -V)
VERSION_COUNT=$(echo "$VERSIONS_TO_SYNC" | wc -l | tr -d ' ')

if [[ -z "$VERSIONS_TO_SYNC" ]]; then
    log_error "No versions to sync based on filters"
    exit 1
fi

# Get unique branches
BRANCHES=$(for v in $VERSIONS_TO_SYNC; do get_branch_name "$v"; done | sort -V | uniq)
BRANCH_COUNT=$(echo "$BRANCHES" | wc -l | tr -d ' ')

log_info "Will sync $VERSION_COUNT versions across $BRANCH_COUNT branches"

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "DRY RUN - Would create these branches and versions:"
    for branch in $BRANCHES; do
        echo ""
        echo "  Branch: $branch"
        # Get versions for this branch
        for v in $VERSIONS_TO_SYNC; do
            if [[ "$(get_branch_name "$v")" == "$branch" ]]; then
                echo "    - $v"
            fi
        done
    done
    echo ""
    exit 0
fi

# Store current branch to return to later
ORIGINAL_BRANCH=$(git -C "$PACKAGE_DIR" branch --show-current)

# Backup scripts and templates since they get deleted during sync
BACKUP_DIR=$(mktemp -d)
cp -r "$PACKAGE_DIR/scripts" "$BACKUP_DIR/"
cp -r "$PACKAGE_DIR/templates" "$BACKUP_DIR/"
cp "$PACKAGE_DIR/README.md" "$BACKUP_DIR/" 2>/dev/null || true

# Track results
SYNCED_COUNT=0
FAILED_COUNT=0

# Process each branch
for BRANCH_NAME in $BRANCHES; do
    log_step "Processing branch: $BRANCH_NAME"

    cd "$PACKAGE_DIR"

    # Check if branch exists locally or remotely
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
        git checkout "$BRANCH_NAME"
    elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"; then
        git checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME"
    else
        # Create new branch from main
        git checkout main 2>/dev/null || git checkout -b main
        git checkout -b "$BRANCH_NAME"
    fi

    # Process each version in this branch
    for VERSION in $VERSIONS_TO_SYNC; do
        # Skip if this version doesn't belong to this branch
        if [[ "$(get_branch_name "$VERSION")" != "$BRANCH_NAME" ]]; then
            continue
        fi

        log_version "Processing WordPress $VERSION on branch $BRANCH_NAME..."

        # Restore scripts and templates (they get deleted after each sync)
        cp -r "$BACKUP_DIR/scripts" "$PACKAGE_DIR/" 2>/dev/null || true
        cp -r "$BACKUP_DIR/templates" "$PACKAGE_DIR/" 2>/dev/null || true
        cp "$BACKUP_DIR/README.md" "$PACKAGE_DIR/" 2>/dev/null || true

        # Run the single version sync script
        if "$PACKAGE_DIR/scripts/sync-wordpress.sh" "$VERSION" --tag; then
            SYNCED_COUNT=$((SYNCED_COUNT + 1))
            log_info "Successfully synced WordPress $VERSION"
        else
            FAILED_COUNT=$((FAILED_COUNT + 1))
            log_error "Failed to sync WordPress $VERSION"
        fi
    done
done

# Restore scripts and templates to main branch
cd "$PACKAGE_DIR"
git checkout main 2>/dev/null || git checkout -b main
cp -r "$BACKUP_DIR/scripts" "$PACKAGE_DIR/"
cp -r "$BACKUP_DIR/templates" "$PACKAGE_DIR/"
cp "$BACKUP_DIR/README.md" "$PACKAGE_DIR/" 2>/dev/null || true

# Clean up backup
rm -rf "$BACKUP_DIR"

# Return to original branch
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

# Push if requested
if [[ "$DO_PUSH" == true ]]; then
    log_step "Pushing to remote..."
    cd "$PACKAGE_DIR"

    # Push main branch
    git push origin main 2>/dev/null || log_warn "Failed to push main"

    # Push all version branches
    for branch in $BRANCHES; do
        git push origin "$branch" --tags || log_warn "Failed to push $branch"
    done
fi

# Summary
echo ""
echo "========================================"
echo "  Sync All Versions Complete"
echo "========================================"
echo "  Versions synced: $SYNCED_COUNT"
echo "  Versions failed: $FAILED_COUNT"
echo "  Branches: $BRANCH_COUNT"
echo ""
echo "  Branches created/updated:"
for branch in $BRANCHES; do
    echo "    - $branch"
done
echo ""
if [[ "$DO_PUSH" == true ]]; then
    echo "  Changes pushed to remote"
else
    echo "  Run with --push to publish"
fi
echo "========================================"
