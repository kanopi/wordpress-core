# kanopi/wordpress

WordPress core with Composer scaffold support for flexible project layouts.

## Branch Structure

- **main** - Contains only scripts and templates (no WordPress files)
- **Version tags** (e.g., `6.4.3`, `6.5.0`) - Contains WordPress core files at project root

## Usage

In your project's `composer.json`:

```json
{
    "require": {
        "kanopi/wordpress": "^6.4"
    },
    "extra": {
        "wp-scaffold": {
            "locations": {
                "web-root": "./public"
            }
        }
    }
}
```

## Branch Structures

### main branch (scripts only)

```
wordpress-core/
├── README.md
├── scripts/
│   ├── sync-wordpress.sh
│   └── sync-all-versions.sh
└── templates/
    ├── composer.json.template
    └── scaffold-overrides/
        ├── htaccess
        ├── index.php
        ├── robots.txt
        ├── wp-config-sample.php
        └── wp-content/index.php
```

### Version tags (e.g., 6.4.3)

```
wordpress-core/
├── composer.json
├── index.php
├── htaccess
├── robots.txt
├── license.txt
├── readme.html
├── wp-activate.php
├── wp-blog-header.php
├── wp-comments-post.php
├── wp-config-sample.php
├── wp-cron.php
├── wp-links-opml.php
├── wp-load.php
├── wp-login.php
├── wp-mail.php
├── wp-settings.php
├── wp-signup.php
├── wp-trackback.php
├── xmlrpc.php
├── wp-admin/
├── wp-includes/
└── wp-content/
    └── index.php
```

Note: Version tags contain only WordPress files - no scripts, templates, or README.

## Scripts

### sync-wordpress.sh

Sync a single WordPress version:

```bash
# Download and prepare (no git operations)
./scripts/sync-wordpress.sh 6.4.3

# Download, prepare, and commit
./scripts/sync-wordpress.sh 6.4.3 --commit

# Download, prepare, commit, and tag
./scripts/sync-wordpress.sh 6.4.3 --tag

# Download, prepare, commit, tag, and push
./scripts/sync-wordpress.sh 6.4.3 --push
```

### sync-all-versions.sh

Sync multiple WordPress versions from GitHub:

```bash
# Dry run - see what would be synced
./scripts/sync-all-versions.sh --dry-run

# Sync all versions >= 6.0
./scripts/sync-all-versions.sh --min-version 6.0

# Sync a specific version
./scripts/sync-all-versions.sh --single 6.4.3

# Sync and push to remote
./scripts/sync-all-versions.sh --min-version 6.0 --push

# Create separate branches for each major version
./scripts/sync-all-versions.sh --branch-per-major --push
```

## Templates

- `templates/composer.json.template` - Template for generated composer.json
- `templates/scaffold-overrides/` - Custom scaffold files that override WordPress defaults

### Placeholders

The composer.json template uses these placeholders:

- `{{VERSION}}` - Full version (e.g., `6.4.3`)
- `{{MAJOR_VERSION}}` - Major version number (e.g., `6`)

## How It Works

1. Scripts fetch WordPress from wordpress.org
2. Core files are placed directly in the package root
3. Custom scaffold files from `templates/scaffold-overrides/` replace WordPress defaults
4. `composer.json` is generated from template with version substituted
5. Git tag is created matching the WordPress version

## File Mapping

When installed, files are scaffolded from package root to your web root:

| Source | Destination |
|--------|-------------|
| `wp-admin/` | `[web-root]/wp-admin/` |
| `wp-includes/` | `[web-root]/wp-includes/` |
| `wp-*.php` | `[web-root]/wp-*.php` |
| `index.php` | `[web-root]/index.php` |
| `htaccess` | `[web-root]/.htaccess` |
| `robots.txt` | `[web-root]/robots.txt` |

## Requirements

- PHP >= 7.4
- kanopi/wp-core-composer-scaffold ^1.0
