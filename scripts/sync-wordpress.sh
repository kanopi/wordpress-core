#!/usr/bin/env bash
#
# WordPress Single Version Sync Script
# Downloads a specific WordPress version and prepares it for release.
#
# Usage:
#   ./scripts/sync-wordpress.sh <version> [--commit] [--tag] [--push]
#
# Examples:
#   ./scripts/sync-wordpress.sh 6.4.3              # Stable version
#   ./scripts/sync-wordpress.sh 6.5-beta1          # Beta version
#   ./scripts/sync-wordpress.sh 6.5-RC1            # Release candidate
#   ./scripts/sync-wordpress.sh 6.4.3 --tag        # Download, prepare, commit, tag
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATES_DIR="$PACKAGE_DIR/templates"
TEMP_DIR=$(mktemp -d)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

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

usage() {
    echo "Usage: $0 <version> [--commit] [--tag] [--push]"
    echo ""
    echo "Arguments:"
    echo "  version     WordPress version to sync"
    echo "              Stable: 6.4.3, 6.5"
    echo "              Beta:   6.5-beta1, 6.5-beta2"
    echo "              RC:     6.5-RC1, 6.5-RC2"
    echo ""
    echo "Options:"
    echo "  --commit    Create a git commit"
    echo "  --tag       Create a git tag (implies --commit)"
    echo "  --push      Push to remote (implies --tag)"
    echo ""
    echo "Examples:"
    echo "  $0 6.4.3"
    echo "  $0 6.5-beta1 --tag"
    echo "  $0 6.5-RC1 --push"
    exit 1
}

# Normalize WordPress version to Composer-compatible format
# WordPress: 6.5-beta1, 6.5-RC1, 6.5, 6.5.1
# Composer:  6.5.0-beta1, 6.5.0-RC1, 6.5.0, 6.5.1
normalize_version() {
    local version="$1"
    local normalized=""

    # Check if it's a pre-release version (contains - followed by alpha/beta/RC)
    if [[ "$version" =~ ^([0-9]+\.[0-9]+)(\.([0-9]+))?(-(.+))?$ ]]; then
        local major_minor="${BASH_REMATCH[1]}"
        local patch="${BASH_REMATCH[3]:-0}"
        local prerelease="${BASH_REMATCH[5]:-}"

        if [[ -n "$prerelease" ]]; then
            # Normalize pre-release identifier (beta1 -> beta.1, RC1 -> RC.1)
            # Actually, Composer accepts both formats, keep as-is for clarity
            normalized="${major_minor}.${patch}-${prerelease}"
        else
            normalized="${major_minor}.${patch}"
        fi
    else
        normalized="$version"
    fi

    echo "$normalized"
}

# Get major.minor from version (handles both 6.5 and 6.5.0-beta1)
get_major_minor() {
    echo "$1" | grep -oE '^[0-9]+\.[0-9]+'
}

# Get major version
get_major() {
    echo "$1" | cut -d. -f1
}

# Parse arguments
if [[ $# -lt 1 ]]; then
    usage
fi

WP_VERSION="$1"  # Original WordPress version (for download URL)
shift

DO_COMMIT=false
DO_TAG=false
DO_PUSH=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --commit)
            DO_COMMIT=true
            shift
            ;;
        --tag)
            DO_TAG=true
            DO_COMMIT=true
            shift
            ;;
        --push)
            DO_PUSH=true
            DO_TAG=true
            DO_COMMIT=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate version format (stable, beta, RC, alpha)
if [[ ! "$WP_VERSION" =~ ^[0-9]+\.[0-9]+((\.[0-9]+)|(-(alpha|beta|RC)[0-9]+))?$ ]]; then
    log_error "Invalid version format: $WP_VERSION"
    log_error "Expected formats:"
    log_error "  Stable: 6.4, 6.4.3"
    log_error "  Beta:   6.5-beta1"
    log_error "  RC:     6.5-RC1"
    exit 1
fi

# Normalize version for Composer
COMPOSER_VERSION=$(normalize_version "$WP_VERSION")
MAJOR_MINOR=$(get_major_minor "$WP_VERSION")
MAJOR_VERSION=$(get_major "$WP_VERSION")

log_info "WordPress version: $WP_VERSION"
log_info "Composer version: $COMPOSER_VERSION"
log_info "Branch: ${MAJOR_MINOR}.x"

# Step 1: Download WordPress
log_step "Downloading WordPress $WP_VERSION..."
DOWNLOAD_URL="https://wordpress.org/wordpress-${WP_VERSION}.tar.gz"

if ! curl -sL "$DOWNLOAD_URL" -o "$TEMP_DIR/wordpress.tar.gz"; then
    log_error "Failed to download WordPress $WP_VERSION from $DOWNLOAD_URL"
    exit 1
fi

# Step 2: Extract WordPress
log_step "Extracting WordPress..."
tar -xzf "$TEMP_DIR/wordpress.tar.gz" -C "$TEMP_DIR"

if [[ ! -d "$TEMP_DIR/wordpress" ]]; then
    log_error "Extraction failed - wordpress directory not found"
    exit 1
fi

# Step 3: Clean package directory (remove old WordPress files, keep scripts/templates)
log_step "Cleaning package directory..."
cd "$PACKAGE_DIR"

# Remove WordPress directories and files from root (but keep scripts, templates, README, .git)
rm -rf wp-admin wp-includes wp-content 2>/dev/null || true
rm -f wp-*.php index.php xmlrpc.php license.txt readme.html htaccess robots.txt 2>/dev/null || true
rm -f composer.json 2>/dev/null || true

# Step 4: Copy WordPress core files to package root
log_step "Copying WordPress core files to root..."

# Copy directories
cp -r "$TEMP_DIR/wordpress/wp-admin" "$PACKAGE_DIR/"
cp -r "$TEMP_DIR/wordpress/wp-includes" "$PACKAGE_DIR/"

# Create wp-content directory
mkdir -p "$PACKAGE_DIR/wp-content"

# Copy PHP files from root (except index.php and wp-config-sample.php - we use our own)
for file in "$TEMP_DIR/wordpress/"*.php; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        if [[ "$filename" != "index.php" && "$filename" != "wp-config-sample.php" ]]; then
            cp "$file" "$PACKAGE_DIR/"
        fi
    fi
done

# Copy other files
cp "$TEMP_DIR/wordpress/license.txt" "$PACKAGE_DIR/"
cp "$TEMP_DIR/wordpress/readme.html" "$PACKAGE_DIR/"

# Step 5: Copy scaffold override files (our customized versions)
log_step "Copying scaffold override files..."
cp "$TEMPLATES_DIR/scaffold-overrides/index.php" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/wp-config-sample.php" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/htaccess" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/robots.txt" "$PACKAGE_DIR/"
cp "$TEMPLATES_DIR/scaffold-overrides/wp-content/index.php" "$PACKAGE_DIR/wp-content/"

# Step 6: Generate composer.json from template
log_step "Generating composer.json..."
sed -e "s/{{VERSION}}/$COMPOSER_VERSION/g" \
    -e "s/{{MAJOR_VERSION}}/$MAJOR_VERSION/g" \
    "$TEMPLATES_DIR/composer.json.template" > "$PACKAGE_DIR/composer.json"

# Verify version.php exists
if [[ ! -f "$PACKAGE_DIR/wp-includes/version.php" ]]; then
    log_error "version.php not found - sync may have failed"
    exit 1
fi

# Extract and verify the synced version
SYNCED_VERSION=$(grep -o "\\\$wp_version = '[^']*'" "$PACKAGE_DIR/wp-includes/version.php" | cut -d"'" -f2)
log_info "Successfully synced WordPress $SYNCED_VERSION"

# Step 7: Remove build tooling (scripts/templates) for clean release
if [[ "$DO_COMMIT" == true ]]; then
    log_step "Removing build tooling for clean release..."
    rm -rf "$PACKAGE_DIR/scripts" "$PACKAGE_DIR/templates" "$PACKAGE_DIR/README.md"
fi

# Step 8: Git operations
if [[ "$DO_COMMIT" == true ]]; then
    log_step "Creating git commit..."
    cd "$PACKAGE_DIR"
    git add -A
    git commit -m "WordPress $COMPOSER_VERSION" || log_warn "Nothing to commit"
fi

if [[ "$DO_TAG" == true ]]; then
    log_step "Creating git tag..."
    git tag -a "$COMPOSER_VERSION" -m "WordPress $COMPOSER_VERSION" 2>/dev/null || {
        log_warn "Tag $COMPOSER_VERSION already exists, skipping"
    }
fi

if [[ "$DO_PUSH" == true ]]; then
    log_step "Pushing to remote..."
    CURRENT_BRANCH=$(git branch --show-current)
    git push origin "$CURRENT_BRANCH" --tags
fi

# Count files
FILE_COUNT=$(find "$PACKAGE_DIR" -type f \( -name "*.php" -o -name "*.txt" -o -name "*.html" -o -name "*.css" -o -name "*.js" \) | wc -l | tr -d ' ')

# Summary
echo ""
echo "========================================"
echo "  Sync Complete"
echo "========================================"
echo "  WordPress Version: $SYNCED_VERSION"
echo "  Composer Version:  $COMPOSER_VERSION"
echo "  Package Directory: $PACKAGE_DIR"
echo "  Files synced: $FILE_COUNT"
echo ""
if [[ "$DO_TAG" == true ]]; then
    echo "  Git tag created: $COMPOSER_VERSION"
fi
if [[ "$DO_PUSH" == true ]]; then
    echo "  Changes pushed to remote"
else
    echo "  Run 'git push origin <branch> --tags' to publish"
fi
echo "========================================"
