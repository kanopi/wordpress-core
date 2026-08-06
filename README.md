# kanopi/wordpress-core

A Composer-installable mirror of [WordPress/WordPress](https://github.com/WordPress/WordPress).

Every upstream branch and tag is reproduced here with **one extra commit on top
that adds `composer.json`**. Upstream history is preserved — the overlay
commit's parent is the real upstream commit — so this is a genuine mirror, not a
repackaged release tarball.

The package is `type: wordpress-core`, installed by
[`kanopi/wp-core-installer`](https://github.com/kanopi/wp-core-installer).

---

## Using it in a project

```json
{
    "repositories": [
        { "type": "vcs", "url": "https://github.com/kanopi/wordpress-core" }
    ],
    "require": {
        "kanopi/wordpress-core": "^6.9"
    },
    "extra": {
        "wordpress-install-dir": "public"
    },
    "config": {
        "allow-plugins": {
            "kanopi/wp-core-installer": true
        }
    }
}
```

`kanopi/wp-core-installer` is a hard dependency of every release from WordPress
6.0 up, so you do not need to require it yourself. Once the package is listed on
Packagist the `repositories` block can be dropped.

`extra.wordpress-install-dir` decides where core lands — `"."` for the project
root, `"public"` (the default) or `"public/wp"` for a subdirectory. See the
[installer README](https://github.com/kanopi/wp-core-installer#configuration)
for the full protected-path and `.gitignore` behaviour.

## What you can require

| Constraint | Resolves to | Composer fetches |
|---|---|---|
| `6.9.1`, `^6.9`, `~6.9.0` | tag `6.9.1` | dist archive |
| `6.9.x-dev` | branch `6.9.x` (head of the 6.9 series) | **git source** |
| `dev-6.9-branch` | branch `6.9-branch`, upstream's own name | **git source** |
| `dev-master` | branch `master` — WordPress trunk | **git source** |
| `7.1.x-dev` | branch `7.1.x`, the series trunk currently targets | **git source** |

Every upstream tag back to 1.5 is mirrored — 850+ of them — so any released
WordPress version is installable.

### Branch layout

```
main            tooling only: this README, bin/, .circleci/  (never mirrored)
master          ← GitHub default branch; mirrors upstream master (trunk)
7.1.x           same commit as master, named so Composer derives 7.1.x-dev
7.0-branch      verbatim mirror of upstream
7.0.x           same commit, Composer-friendly alias
…               one pair per WordPress series, back to 1.5
```

Upstream's `X.Y-branch` naming means nothing to Composer, so each series is
published twice: once verbatim, and once as `X.Y.x` — which Composer reads as
`X.Y.x-dev`. Both names point at the same commit. The `X.Y-branch` refs also
carry an `extra.branch-alias` mapping to `X.Y.x-dev`.

### Pre-releases

Upstream tags only stable releases; there are no `-RC` or `-beta` tags to
mirror. Track a pre-release with `dev-master` (currently WordPress
7.1-RC2) or with the series branch, e.g. `7.1.x-dev`.

---

## Running a sync

One command, idempotent — re-running when nothing changed is a no-op:

```bash
bin/mirror.sh --push
```

```bash
bin/mirror.sh --dry-run                  # list what would be mirrored
bin/mirror.sh --only 6.9.1 --push        # a single ref
bin/mirror.sh --only 6.9-branch --push   # a single branch (+ its 6.9.x alias)
bin/mirror.sh --min-version 6.0 --push   # skip tags older than 6.0
bin/mirror.sh --force --push             # rebuild tags already published
bin/mirror.sh --help
```

Requirements: `git`, `python3`, and push access to this repo.

The first run clones ~690 MB of WordPress history into `.mirror/` (gitignored)
and takes a few minutes. Later runs only transfer new commits.

### How it works

1. `git ls-remote` lists what this repo already publishes — ref names only, no
   object transfer.
2. Upstream is fetched into private `refs/upstream/*` namespaces.
3. For each ref, `composer.json` is generated from the WordPress version found
   in that ref's own `wp-includes/version.php`, then spliced onto the upstream
   tree using git plumbing (`read-tree` / `write-tree` / `commit-tree`). No
   working tree is ever checked out, which is what keeps 900 refs fast.
4. Refs are pushed in atomic batches.

Overlay commits are **reproducible**: identity and timestamp are derived from
the upstream commit, so rebuilding a ref yields a byte-identical commit SHA and
nothing gets pushed. Their messages carry `[skip ci]` so mirroring 900 refs
doesn't spawn 900 CircleCI pipelines.

### Configuration

`bin/mirror.sh` reads these from the environment:

| Variable | Default |
|---|---|
| `UPSTREAM_URL` | `https://github.com/WordPress/WordPress.git` |
| `TARGET_URL` | `git@github.com:kanopi/wordpress-core.git` |
| `PACKAGE_NAME` | `kanopi/wordpress-core` |
| `INSTALLER_NAME` | `kanopi/wp-core-installer` |
| `INSTALLER_CONSTRAINT` | `^1.1` |
| `INSTALLER_MIN_WP` | `6.0` — older releases only `suggest` the installer |
| `TOOLING_BRANCH` | `main` — never mirrored over |
| `EXCLUDE_BRANCHES` | `^dependabot/` — upstream PR branches, skipped as noise |
| `WORKDIR` | `./.mirror` |

---

## CircleCI

`.circleci/config.yml` defines two workflows:

- **`sync`** — runs `bin/mirror.sh --push`. Fires only when a pipeline sets the
  `run_mirror` parameter to `true`.
- **`validate`** — shellcheck, a byte-compile of the generator, and
  `composer validate` on its output. Runs on ordinary pushes to `main`.

### Setup

1. Add this project in CircleCI.
2. Create a context named **`github-push`** containing `GITHUB_TOKEN` — a token
   with push access to `kanopi/wordpress-core`.
3. Create the schedule in **Project Settings → Triggers → Add Trigger**
   (CircleCI no longer honours cron blocks in `config.yml`):
   - Repeat: daily, whatever hour suits you
   - Attribution: the account whose token should own the pipeline
   - Branch: **`main`**
   - Pipeline parameters: `run_mirror` = `true`

Set the pipeline parameter, or the scheduled run will do nothing — `sync` is
gated on it.

### Triggering a sync by hand

```bash
curl -X POST https://circleci.com/api/v2/project/gh/kanopi/wordpress-core/pipeline \
  -H "Circle-Token: $CIRCLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"branch": "main", "parameters": {"run_mirror": true}}'
```

Optional parameters: `min_version` (string), `only_refs` (comma-separated
string), `force` (boolean).

```bash
# Re-mirror one release
-d '{"branch": "main", "parameters": {"run_mirror": true, "only_refs": "6.9.1", "force": true}}'
```

---

## Publishing to Packagist

The GitHub **default branch must stay `master`** — that is the ref Packagist
reads for the package name and description, and it is the only mirrored branch
guaranteed to exist. `main` deliberately has no `composer.json`, so Packagist
ignores it and nobody can install the tooling by mistake.

The package is **already registered** at
[packagist.org/packages/kanopi/wordpress-core](https://packagist.org/packages/kanopi/wordpress-core),
so submitting it again fails as a duplicate. Instead, on that page:

1. **Update** — forces a re-crawl so the new refs are indexed.
2. **Settings → un-abandon** — it is currently flagged abandoned from a 2021
   attempt that only ever published 6.5.3.
3. Add the Packagist webhook in GitHub so new tags publish automatically.

The repository must stay **public** for Packagist to index it.

---

## Related packages

- [`kanopi/wp-core-installer`](https://github.com/kanopi/wp-core-installer) —
  the Composer plugin that deploys this package into a web root.
