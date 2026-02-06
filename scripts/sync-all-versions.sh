#!/usr/bin/env bash
#
# WordPress All Versions Sync Script
# Fetches all WordPress version tags from GitHub and creates corresponding releases.
#
# Usage:
#   ./scripts/sync-all-versions.sh [options]
#
# Options:
#   --min-version X.Y    Only sync versions >= X.Y (default: 5.0)
#   --max-version X.Y    Only sync versions <= X.Y (default: latest)
#   --single X.Y.Z       Sync only a single specific version
#   --dry-run            Show what would be done without making changes
#   --push               Push branches and tags to remote
#   --branch-per-major   Create a branch for each major version (e.g., 6.x)
#
# Examples:
#   ./scripts/sync-all-versions.sh --min-version 6.0
#   ./scripts/sync-all-versions.sh --single 6.4.3 --push
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
    echo "  --min-version X.Y    Only sync versions >= X.Y (default: 5.0)"
    echo "  --max-version X.Y    Only sync versions <= X.Y (default: latest)"
    echo "  --single X.Y.Z       Sync only a single specific version"
    echo "  --dry-run            Show what would be done without making changes"
    echo "  --push               Push branches and tags to remote"
    echo "  --branch-per-major   Create a branch for each major version (e.g., 6.x)"
    echo ""
    echo "Examples:"
    echo "  $0 --min-version 6.0"
    echo "  $0 --single 6.4.3 --push"
    echo "  $0 --dry-run"
    exit 1
}

# Default options
MIN_VERSION="5.0"
MAX_VERSION=""
SINGLE_VERSION=""
DRY_RUN=false
DO_PUSH=false
BRANCH_PER_MAJOR=false

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
        --branch-per-major)
            BRANCH_PER_MAJOR=true
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

# Function to get major.minor from version
get_major_minor() {
    echo "$1" | cut -d. -f1,2
}

# Function to get major from version
get_major() {
    echo "$1" | cut -d. -f1
}

# Fetch all WordPress version tags from GitHub
log_step "Fetching WordPress version tags from GitHub..."

# Use GitHub API to get all tags
TAGS_JSON=$(curl -sL "https://api.github.com/repos/WordPress/WordPress/tags?per_page=100")

# Extract version numbers (filter out non-version tags)
ALL_VERSIONS=$(echo "$TAGS_JSON" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -V)

# If we need more than 100 tags, paginate
PAGE=2
while true; do
    NEXT_JSON=$(curl -sL "https://api.github.com/repos/WordPress/WordPress/tags?per_page=100&page=$PAGE")
    NEXT_VERSIONS=$(echo "$NEXT_JSON" | grep -o '"name": "[^"]*"' | cut -d'"' -f4 | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' 2>/dev/null || true)

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

log_info "Found $(echo "$ALL_VERSIONS" | wc -l | tr -d ' ') WordPress versions"

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

log_info "Will sync $VERSION_COUNT versions"

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "DRY RUN - Would sync these versions:"
    echo "$VERSIONS_TO_SYNC" | while read -r v; do
        echo "  - $v"
    done
    echo ""
    exit 0
fi

# Store current branch to return to later
ORIGINAL_BRANCH=$(git -C "$PACKAGE_DIR" branch --show-current)

# Track branches created for major versions
declare -A MAJOR_BRANCHES

# Sync each version
SYNCED_COUNT=0
FAILED_COUNT=0

for VERSION in $VERSIONS_TO_SYNC; do
    log_version "Processing WordPress $VERSION..."

    MAJOR=$(get_major "$VERSION")
    MAJOR_MINOR=$(get_major_minor "$VERSION")

    # Determine target branch
    if [[ "$BRANCH_PER_MAJOR" == true ]]; then
        TARGET_BRANCH="${MAJOR}.x"
    else
        TARGET_BRANCH="main"
    fi

    # Create/switch to branch if using per-major branches
    if [[ "$BRANCH_PER_MAJOR" == true ]]; then
        cd "$PACKAGE_DIR"

        # Check if branch exists
        if git show-ref --verify --quiet "refs/heads/$TARGET_BRANCH"; then
            git checkout "$TARGET_BRANCH"
        else
            # Create branch from main
            git checkout main
            git checkout -b "$TARGET_BRANCH"
            MAJOR_BRANCHES[$TARGET_BRANCH]=1
        fi
    fi

    # Run the single version sync script
    if "$SCRIPT_DIR/sync-wordpress.sh" "$VERSION" --tag; then
        SYNCED_COUNT=$((SYNCED_COUNT + 1))
        log_info "Successfully synced WordPress $VERSION"
    else
        FAILED_COUNT=$((FAILED_COUNT + 1))
        log_error "Failed to sync WordPress $VERSION"
    fi
done

# Return to original branch
cd "$PACKAGE_DIR"
git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true

# Push if requested
if [[ "$DO_PUSH" == true ]]; then
    log_step "Pushing to remote..."
    cd "$PACKAGE_DIR"

    if [[ "$BRANCH_PER_MAJOR" == true ]]; then
        # Push all major branches
        for branch in "${!MAJOR_BRANCHES[@]}"; do
            git push origin "$branch" --tags || log_warn "Failed to push $branch"
        done
    else
        git push origin main --tags || log_warn "Failed to push main"
    fi
fi

# Summary
echo ""
echo "========================================"
echo "  Sync All Versions Complete"
echo "========================================"
echo "  Versions synced: $SYNCED_COUNT"
echo "  Versions failed: $FAILED_COUNT"
echo ""
if [[ "$BRANCH_PER_MAJOR" == true ]]; then
    echo "  Branches created: ${!MAJOR_BRANCHES[*]}"
fi
if [[ "$DO_PUSH" == true ]]; then
    echo "  Changes pushed to remote"
else
    echo "  Run with --push to publish"
fi
echo "========================================"
