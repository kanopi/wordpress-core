#!/usr/bin/env python3
"""Emit the composer.json that gets overlaid onto a mirrored WordPress ref.

Output is deterministic for a given set of inputs: the same ref always
produces byte-identical JSON, which is what lets mirror.sh build reproducible
overlay commits and skip work it has already done.
"""

import argparse
import json
import re
import sys


def parse_branch_alias(raw):
    """Parse 'dev-6.9-branch=6.9.x-dev,dev-master=7.1.x-dev' into a dict."""
    aliases = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if not pair:
            continue
        if "=" not in pair:
            sys.exit("Invalid --branch-alias entry (expected KEY=VALUE): %s" % pair)
        key, value = pair.split("=", 1)
        aliases[key.strip()] = value.strip()
    return aliases


def major_minor(version):
    """'6.9.1' -> (6, 9). '7.1-RC2-63095' -> (7, 1). Unparseable -> None."""
    match = re.match(r"^(\d+)\.(\d+)", version or "")
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def at_least(version, floor):
    """True when `version` is >= `floor`, comparing on major.minor only."""
    left, right = major_minor(version), major_minor(floor)
    if left is None or right is None:
        return False
    return left >= right


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True,
                        help="Composer package name, e.g. kanopi/wordpress-core")
    parser.add_argument("--source-url", default="https://github.com/kanopi/wordpress-core",
                        help="Homepage/support URL for the mirror repository")
    parser.add_argument("--wp-version", default="",
                        help="Raw $wp_version from the ref's wp-includes/version.php")
    parser.add_argument("--php-version", default="",
                        help="Raw $required_php_version from the ref's wp-includes/version.php")
    parser.add_argument("--installer", default="",
                        help="Composer plugin that installs this package; omit to skip")
    parser.add_argument("--installer-constraint", default="^1.1",
                        help="Version constraint for --installer")
    parser.add_argument("--installer-min-wp", default="6.0",
                        help="Hard-require --installer only from this WP version up; "
                             "older refs list it under 'suggest' instead")
    parser.add_argument("--branch-alias", default="",
                        help="Comma-separated KEY=VALUE extra.branch-alias entries")
    args = parser.parse_args()

    require = {}
    if args.php_version:
        require["php"] = ">=%s" % args.php_version

    suggest = {}
    if args.installer:
        if at_least(args.wp_version, args.installer_min_wp):
            require[args.installer] = args.installer_constraint
        else:
            suggest[args.installer] = (
                "Installs WordPress core into your web root "
                "(requires PHP 8.0+, so it is not hard-required on this release)."
            )

    data = {
        "name": args.package,
        "description": "WordPress core, mirrored from WordPress/WordPress for Composer.",
        "type": "wordpress-core",
        "license": "GPL-2.0-or-later",
        "homepage": "https://wordpress.org/",
        "keywords": ["wordpress", "core", "cms", "blog"],
        "authors": [
            {"name": "WordPress Community", "homepage": "https://wordpress.org/about/"}
        ],
        "support": {
            "source": args.source_url,
            "issues": "%s/issues" % args.source_url.rstrip("/"),
            "docs": "https://developer.wordpress.org/",
        },
        "require": require,
    }

    if suggest:
        data["suggest"] = suggest

    aliases = parse_branch_alias(args.branch_alias)
    if aliases:
        data["extra"] = {"branch-alias": aliases}

    # Deliberately no "version" key: Composer must derive versions from the git
    # ref, otherwise branch refs report a fixed tag version and `6.9.x-dev`
    # never resolves.
    sys.stdout.write(json.dumps(data, indent=4) + "\n")


if __name__ == "__main__":
    main()
