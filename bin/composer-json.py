#!/usr/bin/env python3
"""Emit the composer.json that gets overlaid onto a mirrored WordPress ref.

Output is deterministic for a given set of inputs: the same ref always
produces byte-identical JSON, which is what lets mirror.sh build reproducible
overlay commits and skip work it has already done.
"""

import argparse
import json
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", required=True,
                        help="Composer package name, e.g. kanopi/wordpress-core")
    parser.add_argument("--source-url", default="https://github.com/kanopi/wordpress-core",
                        help="Homepage/support URL for the mirror repository")
    parser.add_argument("--php-version", default="",
                        help="Raw $required_php_version from the ref's wp-includes/version.php")
    parser.add_argument("--branch-alias", default="",
                        help="Comma-separated KEY=VALUE extra.branch-alias entries")
    args = parser.parse_args()

    # Deliberately no dependency on an installer plugin. Which installer
    # deploys core is the consuming project's choice, and pinning one here
    # would drag its PHP floor onto every WordPress release we mirror.
    require = {}
    if args.php_version:
        require["php"] = ">=%s" % args.php_version

    data = {
        "name": args.package,
        "description": "WordPress core, mirrored from wordpress.org for Composer.",
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

    aliases = parse_branch_alias(args.branch_alias)
    if aliases:
        data["extra"] = {"branch-alias": aliases}

    # Deliberately no "version" key: Composer must derive versions from the git
    # ref, otherwise branch refs report a fixed tag version and `6.9.x-dev`
    # never resolves.
    sys.stdout.write(json.dumps(data, indent=4) + "\n")


if __name__ == "__main__":
    main()
