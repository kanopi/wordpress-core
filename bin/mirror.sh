#!/usr/bin/env bash
#
# Mirror WordPress core into a Composer-installable package.
#
# The source is wordpress.org's own git mirror of the core build repository
# (git://core.git.wordpress.org/, the git face of core.svn.wordpress.org).
# GitHub's WordPress/WordPress mirrors the same SVN repo, but its tag and
# release-branch sync stalls periodically — in August 2026 it sat five security
# releases behind, 7.0.4 among them — so we go to the origin instead.
#
# Every upstream branch and tag is reproduced here with one extra commit on top
# that adds composer.json. Upstream history is preserved (the overlay commit's
# parent is the upstream commit), so this repo is a genuine mirror rather than a
# rebuild from release tarballs.
#
# Refs produced (note the upstream -> published renames):
#
#   upstream tag  6.9.1        ->  tag     6.9.1              (Composer: 6.9.1)
#   upstream tag  7.0.0        ->  tag     7.0                (Composer: 7.0)
#   upstream      6.9          ->  branch  6.9-branch         (Composer: dev-6.9-branch)
#                              ->  branch  6.9.x              (Composer: 6.9.x-dev)
#   upstream      trunk        ->  branch  master             (Composer: dev-master)
#                              ->  branch  7.2.x              (Composer: 7.2.x-dev)
#
# Published names are deliberately unchanged from when this mirror sourced
# GitHub, so existing "dev-master", "dev-6.9-branch" and "7.0" constraints keep
# resolving. See published_branch() and published_tag().
#
# The tooling branch (main) is never touched.
#
# Usage:
#   bin/mirror.sh --push                    # full sync, publish everything new
#   bin/mirror.sh --dry-run                 # show what would happen
#   bin/mirror.sh --only 6.9.1 --push       # one ref
#   bin/mirror.sh --min-version 6.0 --push  # skip tags older than 6.0
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Configuration (all overridable via environment) -------------------------

UPSTREAM_URL="${UPSTREAM_URL:-git://core.git.wordpress.org/}"
TARGET_URL="${TARGET_URL:-git@github.com:kanopi/wordpress-core.git}"
PACKAGE_NAME="${PACKAGE_NAME:-kanopi/wordpress-core}"
SOURCE_URL="${SOURCE_URL:-https://github.com/kanopi/wordpress-core}"
TOOLING_BRANCH="${TOOLING_BRANCH:-main}"
# Branches upstream carries that must not be mirrored:
#
#   master   abandoned on core.git.wordpress.org — last touched 2021-11-08 and
#            still reads $wp_version 5.9-alpha-52035. The live trunk there is
#            "trunk". Mirroring this would publish 5.9-alpha as dev-master.
#   fixes-*  one-off core fix branches, not WordPress series.
#
# If UPSTREAM_URL is ever pointed back at GitHub, override this — on that mirror
# "master" IS the live trunk, and "^dependabot/" is what needs excluding.
EXCLUDE_BRANCHES="${EXCLUDE_BRANCHES:-^(master$|fixes-)}"
WORKDIR="${WORKDIR:-$ROOT/.mirror}"
COMMIT_NAME="${COMMIT_NAME:-Kanopi CI}"
COMMIT_EMAIL="${COMMIT_EMAIL:-ci@kanopi.com}"
PUSH_BATCH="${PUSH_BATCH:-150}"

# --- Options -----------------------------------------------------------------

DO_PUSH=false
DRY_RUN=false
FORCE=false
MIN_VERSION=""
ONLY_REFS=""
SKIP_TAGS=false
SKIP_BRANCHES=false

usage() {
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
    cat <<'EOF'
Options:
  --push                 Push mirrored refs to the target repository
  --dry-run              Report what would be mirrored; change nothing
  --force                Rebuild tags that already exist on the target
  --min-version X.Y      Skip tags older than X.Y
  --only REF[,REF...]    Mirror only these upstream refs (tag or branch names)
  --tags-only            Skip branches
  --branches-only        Skip tags
  --workdir PATH         Object cache directory (default: ./.mirror)
  --target URL           Target repository (default: kanopi/wordpress-core)
  -h, --help             Show this help
EOF
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)          DO_PUSH=true; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --force)         FORCE=true; shift ;;
        --min-version)   MIN_VERSION="${2:?--min-version needs a value}"; shift 2 ;;
        --only)          ONLY_REFS="${2:?--only needs a value}"; shift 2 ;;
        --tags-only)     SKIP_BRANCHES=true; shift ;;
        --branches-only) SKIP_TAGS=true; shift ;;
        --workdir)       WORKDIR="${2:?--workdir needs a value}"; shift 2 ;;
        --target)        TARGET_URL="${2:?--target needs a value}"; shift 2 ;;
        -h|--help)       usage 0 ;;
        *)               echo "Unknown option: $1" >&2; usage ;;
    esac
done

# --- Output helpers ----------------------------------------------------------

if [[ -t 1 ]]; then
    C_INFO=$'\033[0;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[0;31m'
    C_STEP=$'\033[0;34m'; C_OFF=$'\033[0m'
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_STEP=""; C_OFF=""
fi

info() { echo "${C_INFO}[info]${C_OFF} $*"; }
warn() { echo "${C_WARN}[warn]${C_OFF} $*" >&2; }
err()  { echo "${C_ERR}[error]${C_OFF} $*" >&2; }
step() { echo; echo "${C_STEP}==>${C_OFF} $*"; }

# --- Preflight ---------------------------------------------------------------

command -v git >/dev/null || { err "git is required"; exit 1; }
command -v python3 >/dev/null || { err "python3 is required"; exit 1; }

COMPOSER_JSON_BIN="$ROOT/bin/composer-json.py"
[[ -f "$COMPOSER_JSON_BIN" ]] || { err "missing $COMPOSER_JSON_BIN"; exit 1; }

# Everything below operates on a bare object cache; no working tree is ever
# checked out, which is what keeps a 690 MB mirror tolerably fast.
if [[ ! -d "$WORKDIR" ]]; then
    step "Creating object cache at $WORKDIR"
    git init --bare --quiet "$WORKDIR"
fi

export GIT_DIR="$WORKDIR"

git remote set-url upstream "$UPSTREAM_URL" 2>/dev/null \
    || git remote add upstream "$UPSTREAM_URL"
git remote set-url target "$TARGET_URL" 2>/dev/null \
    || git remote add target "$TARGET_URL"

# Never print the target URL directly: in CI it carries an access token.
TARGET_DISPLAY="$(printf '%s' "$TARGET_URL" | sed -E 's#(https?://)[^@/]*@#\1#')"

# --- Fetch -------------------------------------------------------------------

# Only the target's ref *names* matter (to know what is already published), so
# ls-remote is used instead of a fetch — no object transfer, near-instant.
step "Listing target refs ($TARGET_DISPLAY)"
TARGET_TAGS="$(mktemp "${TMPDIR:-/tmp}/wp-mirror-tags.XXXXXX")"
TARGET_HEADS="$(mktemp "${TMPDIR:-/tmp}/wp-mirror-heads.XXXXXX")"
LS_REMOTE="$(mktemp "${TMPDIR:-/tmp}/wp-mirror-lsremote.XXXXXX")"
: > "$TARGET_TAGS"; : > "$TARGET_HEADS"; : > "$LS_REMOTE"
trap 'rm -f "$TARGET_TAGS" "$TARGET_HEADS" "$LS_REMOTE"' EXIT

if git ls-remote --heads --tags target > "$LS_REMOTE" 2>/dev/null; then
    sed -n 's#.*refs/tags/##p' "$LS_REMOTE" | sed 's#\^{}$##' | sort -u > "$TARGET_TAGS"
    # "<sha> <branch>" pairs, so an unchanged branch can be left unpushed.
    sed -n 's#^\([0-9a-f]*\)[[:space:]]*refs/heads/#\1 #p' "$LS_REMOTE" | sort -u > "$TARGET_HEADS"
    info "Target already publishes $(wc -l < "$TARGET_TAGS" | tr -d ' ') tag(s)," \
         "$(wc -l < "$TARGET_HEADS" | tr -d ' ') branch(es)"
else
    warn "Target repository is empty or unreachable; treating every ref as new"
fi

# Is branch $1 already at commit $2 on the target?
target_head_matches() {
    grep -Fxq "$2 $1" "$TARGET_HEADS"
}

step "Fetching upstream ($UPSTREAM_URL)"
info "First run clones the full WordPress history (~690 MB) and may take a few minutes."
# --prune matters after a source switch: refs the previous upstream carried under
# its own naming (6.9-branch, dependabot/*, tag 6.9) are dropped from the cache,
# so refs/upstream/* always reflects exactly one upstream.
if ! git fetch --prune --no-tags upstream \
    '+refs/heads/*:refs/upstream/heads/*' \
    '+refs/tags/*:refs/upstream/tags/*'; then
    err "Fetch from $UPSTREAM_URL failed."
    case "$UPSTREAM_URL" in
        git://*)
            err "git:// speaks TCP port 9418. Confirm outbound access to it —"
            err "restricted networks and some CI images block that port."
            ;;
    esac
    exit 1
fi

# --- Ref inspection ----------------------------------------------------------

# Read a variable out of a ref's wp-includes/version.php, e.g.
#   read_version_var 6.9.1 wp_version -> 6.9.1
read_version_var() {
    local commit="$1" var="$2"
    git show "$commit:wp-includes/version.php" 2>/dev/null \
        | grep -m1 -E "^\\\$${var}[[:space:]]*=" \
        | cut -d"'" -f2 \
        || true
}

# major.minor of a version string: 6.9.1 -> 6.9, 7.1-RC2-63095 -> 7.1
major_minor() {
    printf '%s' "$1" | grep -oE '^[0-9]+\.[0-9]+' || true
}

# --- Upstream -> published ref names -----------------------------------------
#
# wordpress.org's git mirror names refs differently from GitHub's, which this
# mirror sourced previously. Renaming on the way out keeps every constraint
# already published to Packagist resolving:
#
#   upstream trunk  ->  master        (so dev-master keeps working, and the
#                                      GitHub default branch Packagist reads
#                                      for the package name still exists)
#   upstream 6.9    ->  6.9-branch    (so dev-6.9-branch keeps working)
#   upstream 7.0.0  ->  7.0           (WordPress, SVN and every tag already
#                                      published call it 7.0; Composer
#                                      normalises 7.0 and 7.0.0 to the same
#                                      version, so publishing both collides)
#
# Anything unrecognised passes through untouched.

published_branch() {
    local branch="$1"
    if [[ "$branch" == trunk ]]; then
        printf 'master'
    elif [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]]; then
        printf '%s-branch' "$branch"
    else
        printf '%s' "$branch"
    fi
}

published_tag() {
    if [[ "$1" =~ ^([0-9]+\.[0-9]+)\.0$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$1"
    fi
}

# Which X.Y series does an upstream branch own, if any?
#
# Only the trunk branch and a bare "X.Y" series branch earn a Composer-friendly
# X.Y.x alias. Upstream also carries strays (one-off "fixes-*" branches, and on
# GitHub a bare "5.3" whose version.php reads 5.4); letting those claim a series
# ref would collide with the real series branch and abort the atomic push.
#
# The master/*-branch arms are kept so the script still works if UPSTREAM_URL is
# pointed back at GitHub, where those are the trunk and series names.
series_for_branch() {
    local branch="$1" commit="$2"
    if [[ "$branch" == trunk || "$branch" == master ]]; then
        major_minor "$(read_version_var "$commit" wp_version)"
    elif [[ "$branch" =~ ^[0-9]+\.[0-9]+$ ]]; then
        major_minor "$branch"
    else
        case "$branch" in
            *-branch) major_minor "${branch%-branch}" ;;
            *)        printf '' ;;
        esac
    fi
}

# Is $1 >= $2, comparing as versions? Empty floor always passes.
version_ge() {
    [[ -z "$2" ]] && return 0
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# Does any of the given names appear in --only? Callers pass both the upstream
# and the published name, so --only 6.9-branch and --only 6.9 both work.
in_only_list() {
    [[ -z "$ONLY_REFS" ]] && return 0
    local item needle
    local -a only_list
    IFS=',' read -ra only_list <<< "$ONLY_REFS"
    for item in "${only_list[@]}"; do
        for needle in "$@"; do
            [[ "${item// /}" == "$needle" ]] && return 0
        done
    done
    return 1
}

# --- Overlay construction ----------------------------------------------------

# build_overlay <upstream-commit> <label> <branch-alias-spec>
#
# Writes a commit whose tree is the upstream tree plus composer.json, parented
# on the upstream commit. Author/committer identity and date are derived from
# the upstream commit, so the resulting sha is reproducible: re-running the
# mirror produces identical commits and pushes become no-ops.
build_overlay() {
    local upstream_commit="$1" label="$2" alias_spec="$3"

    local php_version
    php_version="$(read_version_var "$upstream_commit" required_php_version)"

    local -a json_args=(
        --package "$PACKAGE_NAME"
        --source-url "$SOURCE_URL"
        --php-version "$php_version"
    )
    [[ -n "$alias_spec" ]] && json_args+=(--branch-alias "$alias_spec")

    local blob tree index commit_date
    blob="$(python3 "$COMPOSER_JSON_BIN" "${json_args[@]}" | git hash-object -w --stdin)"

    index="$(mktemp "${TMPDIR:-/tmp}/wp-mirror-index.XXXXXX")"
    GIT_INDEX_FILE="$index" git read-tree "$upstream_commit^{tree}"
    GIT_INDEX_FILE="$index" git update-index --add \
        --cacheinfo "100644,$blob,composer.json"
    tree="$(GIT_INDEX_FILE="$index" git write-tree)"
    rm -f "$index"

    commit_date="$(git show -s --format=%cI "$upstream_commit")"

    # [skip ci] keeps CircleCI from spawning a pipeline for each of the ~900
    # mirrored refs, none of which carry a .circleci/config.yml.
    GIT_AUTHOR_NAME="$COMMIT_NAME" \
    GIT_AUTHOR_EMAIL="$COMMIT_EMAIL" \
    GIT_AUTHOR_DATE="$commit_date" \
    GIT_COMMITTER_NAME="$COMMIT_NAME" \
    GIT_COMMITTER_EMAIL="$COMMIT_EMAIL" \
    GIT_COMMITTER_DATE="$commit_date" \
    git commit-tree "$tree" -p "$upstream_commit" \
        -m "WordPress $label: add composer.json for $PACKAGE_NAME [skip ci]"
}

# --- Plan --------------------------------------------------------------------

declare -a PUSH_REFSPECS=()
declare -a PLAN_TAGS=()
declare -a PLAN_BRANCHES=()
SKIPPED_EXISTING=0
SKIPPED_FILTERED=0
UNCHANGED_BRANCHES=0

if [[ "$SKIP_TAGS" == false ]]; then
    step "Planning tags"
    while read -r tag; do
        [[ -z "$tag" ]] && continue
        pub_tag="$(published_tag "$tag")"

        if ! in_only_list "$tag" "$pub_tag"; then
            SKIPPED_FILTERED=$((SKIPPED_FILTERED + 1)); continue
        fi
        if ! version_ge "$pub_tag" "$MIN_VERSION"; then
            SKIPPED_FILTERED=$((SKIPPED_FILTERED + 1)); continue
        fi
        # Tags are immutable; if we already published one, leave it alone. The
        # comparison is on the published name — upstream 7.0.0 is our 7.0.
        if [[ "$FORCE" == false ]] && grep -Fxq "$pub_tag" "$TARGET_TAGS"; then
            SKIPPED_EXISTING=$((SKIPPED_EXISTING + 1)); continue
        fi

        PLAN_TAGS+=("$tag")
    done < <(git for-each-ref --format='%(refname:strip=3)' refs/upstream/tags | sort -V)

    info "${#PLAN_TAGS[@]} tag(s) to mirror (${SKIPPED_EXISTING} already published, ${SKIPPED_FILTERED} filtered out)"
fi

if [[ "$SKIP_BRANCHES" == false ]]; then
    step "Planning branches"
    while read -r branch; do
        [[ -z "$branch" ]] && continue
        pub_branch="$(published_branch "$branch")"
        [[ "$branch" == "$TOOLING_BRANCH" || "$pub_branch" == "$TOOLING_BRANCH" ]] && continue
        if [[ -n "$EXCLUDE_BRANCHES" ]] && printf '%s' "$branch" | grep -qE "$EXCLUDE_BRANCHES"; then
            SKIPPED_FILTERED=$((SKIPPED_FILTERED + 1)); continue
        fi
        in_only_list "$branch" "$pub_branch" || continue
        PLAN_BRANCHES+=("$branch")
    done < <(git for-each-ref --format='%(refname:strip=3)' refs/upstream/heads | sort -V)

    info "${#PLAN_BRANCHES[@]} branch(es) to mirror"
fi

if [[ "$DRY_RUN" == true ]]; then
    step "Dry run — no objects written, no refs pushed"
    if [[ ${#PLAN_TAGS[@]} -gt 0 ]]; then
        for tag in "${PLAN_TAGS[@]}"; do
            pub_tag="$(published_tag "$tag")"
            if [[ "$pub_tag" != "$tag" ]]; then
                echo "  tag     $tag -> $pub_tag"
            else
                echo "  tag     $tag"
            fi
        done
    fi
    if [[ ${#PLAN_BRANCHES[@]} -gt 0 ]]; then
        for branch in "${PLAN_BRANCHES[@]}"; do
            commit="$(git rev-parse "refs/upstream/heads/$branch")"
            pub_branch="$(published_branch "$branch")"
            series="$(series_for_branch "$branch" "$commit")"
            label="$branch"
            [[ "$pub_branch" != "$branch" ]] && label="$branch -> $pub_branch"
            if [[ -n "$series" ]]; then
                echo "  branch  $label  (+ ${series}.x)"
            else
                echo "  branch  $label"
            fi
        done
    fi
    echo
    info "Re-run with --push to publish."
    exit 0
fi

# --- Build -------------------------------------------------------------------

if [[ ${#PLAN_TAGS[@]} -gt 0 ]]; then
    step "Building ${#PLAN_TAGS[@]} tag overlay commit(s)"
    built=0
    for tag in "${PLAN_TAGS[@]}"; do
        pub_tag="$(published_tag "$tag")"
        upstream_commit="$(git rev-parse "refs/upstream/tags/$tag^{commit}")"
        overlay="$(build_overlay "$upstream_commit" "$pub_tag" "")"
        git update-ref "refs/mirror/tags/$pub_tag" "$overlay"
        PUSH_REFSPECS+=("+refs/mirror/tags/$pub_tag:refs/tags/$pub_tag")
        built=$((built + 1))
        if (( built % 50 == 0 )); then
            info "  … $built/${#PLAN_TAGS[@]}"
        fi
    done
    info "Built $built tag overlay commit(s)"
fi

if [[ ${#PLAN_BRANCHES[@]} -gt 0 ]]; then
    step "Building ${#PLAN_BRANCHES[@]} branch overlay commit(s)"
    CLAIMED_SERIES=" "
    for branch in "${PLAN_BRANCHES[@]}"; do
        refspecs_before=${#PUSH_REFSPECS[@]}
        pub_branch="$(published_branch "$branch")"
        upstream_commit="$(git rev-parse "refs/upstream/heads/$branch")"
        wp_version="$(read_version_var "$upstream_commit" wp_version)"
        series="$(series_for_branch "$branch" "$upstream_commit")"

        # A series ref can only be claimed once per run, or the atomic push
        # would carry two updates for the same destination and fail outright.
        if [[ -n "$series" ]]; then
            if [[ "$CLAIMED_SERIES" == *" ${series} "* || "${series}.x" == "$TOOLING_BRANCH" ]]; then
                warn "  ${series}.x already claimed; mirroring $pub_branch verbatim only"
                series=""
            else
                CLAIMED_SERIES="${CLAIMED_SERIES}${series} "
            fi
        fi

        # Composer derives X.Y.x-dev from a branch literally named X.Y.x, but it
        # cannot guess it from our "X.Y-branch" naming — hence the alias. Keyed
        # on the published name, which is what consumers actually require.
        alias_spec=""
        [[ -n "$series" ]] && alias_spec="dev-${pub_branch}=${series}.x-dev"

        overlay="$(build_overlay "$upstream_commit" "${wp_version:-$pub_branch}" "$alias_spec")"

        git update-ref "refs/mirror/heads/$pub_branch" "$overlay"
        label="$pub_branch"
        unchanged=0

        if target_head_matches "$pub_branch" "$overlay"; then
            unchanged=$((unchanged + 1))
        else
            PUSH_REFSPECS+=("+refs/mirror/heads/$pub_branch:refs/heads/$pub_branch")
        fi

        if [[ -n "$series" && "${series}.x" != "$pub_branch" ]]; then
            git update-ref "refs/mirror/heads/${series}.x" "$overlay"
            label="$pub_branch -> ${series}.x"
            if target_head_matches "${series}.x" "$overlay"; then
                unchanged=$((unchanged + 1))
            else
                PUSH_REFSPECS+=("+refs/mirror/heads/${series}.x:refs/heads/${series}.x")
            fi
        fi

        if [[ "$unchanged" -gt 0 && ${#PUSH_REFSPECS[@]} -eq "$refspecs_before" ]]; then
            UNCHANGED_BRANCHES=$((UNCHANGED_BRANCHES + 1))
        else
            info "  $label  (WordPress ${wp_version:-unknown})"
        fi
    done
    if [[ "$UNCHANGED_BRANCHES" -gt 0 ]]; then
        info "  $UNCHANGED_BRANCHES branch(es) already up to date"
    fi
fi

if [[ ${#PUSH_REFSPECS[@]} -eq 0 ]]; then
    step "Nothing to do — the mirror is already up to date"
    exit 0
fi

# --- Push --------------------------------------------------------------------

if [[ "$DO_PUSH" == false ]]; then
    step "Built ${#PUSH_REFSPECS[@]} ref(s) locally in $WORKDIR"
    info "Re-run with --push to publish them to $TARGET_DISPLAY"
    exit 0
fi

step "Pushing ${#PUSH_REFSPECS[@]} ref(s) to $TARGET_DISPLAY"
info "The first push uploads the full history and can take several minutes."

total=${#PUSH_REFSPECS[@]}
pushed=0
while (( pushed < total )); do
    batch=("${PUSH_REFSPECS[@]:pushed:PUSH_BATCH}")
    git push --atomic target "${batch[@]}"
    pushed=$((pushed + ${#batch[@]}))
    info "  pushed $pushed/$total"
done

step "Done"
info "Mirrored ${#PLAN_TAGS[@]} tag(s) and ${#PLAN_BRANCHES[@]} branch(es) to $TARGET_DISPLAY"
