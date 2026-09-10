#!/usr/bin/env python3
"""Create matching, machine-readable identity for Mega images and releases.

Build host only; never connects to or flashes a router. Public release metadata
is a consistency check, not an independent cryptographic signature.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess

REPOSITORY = "mfoster978/openwrt-zbtlink-zbt-z8803be-mega-edition"
BOARD = "zbtlink,zbt-z8803be"
IMAGE = "openwrt-mediatek-filogic-zbtlink_zbt-z8803be-squashfs-sysupgrade.bin"
VERSION = re.compile(r"firmware-[1-9][0-9]*\.[1-9][0-9]*\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")


def git(root, *args):
    # The builder runs as root over a runner-owned checkout. Trust this explicit
    # recipe path for this invocation only, never all repositories globally.
    root = root.resolve()
    return subprocess.check_output(
        ["git", "-c", "safe.directory=" + str(root), "-C", str(root), *args], text=True
    ).strip()


def identity(root, version=None):
    sha = git(root, "rev-parse", "HEAD")
    if not SHA.fullmatch(sha):
        raise ValueError("Invalid recipe commit")
    # Generated OpenWrt build trees/artifacts are ignored by this repository.
    # Never give modified or untracked recipe inputs a published version tag.
    dirty = bool(git(root, "status", "--porcelain", "--untracked-files=normal"))
    if version and not VERSION.fullmatch(version):
        raise ValueError("Published version must be firmware-NUMBER.ATTEMPT (new builds use UTC YYYYMMDDHHMM)")
    if version and dirty:
        raise ValueError("Cannot label a modified recipe as a published firmware release")
    return {
        "schema": 1, "variant": "mega", "repository": REPOSITORY,
        "board": BOARD, "version": version or "local-" + sha[:12],
        "source_sha": sha, "dirty": dirty,
        "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "base_version": "v25.12.021",
    }


def manifest(build, image, expected_version, expected_sha):
    for field, value in (("schema", 1), ("variant", "mega"),
                         ("repository", REPOSITORY), ("board", BOARD)):
        if build.get(field) != value:
            raise ValueError("Wrong Mega build identity: " + field)
    if not VERSION.fullmatch(expected_version) or build.get("version") != expected_version:
        raise ValueError("Release tag does not match embedded image version")
    if not SHA.fullmatch(expected_sha) or build.get("source_sha") != expected_sha:
        raise ValueError("Recipe commit does not match embedded image commit")
    if build.get("dirty") is not False:
        raise ValueError("Release requires a clean recipe identity")
    if not isinstance(build.get("built_at"), str) or not build["built_at"]:
        raise ValueError("Missing build date")
    if image.is_symlink() or image.name != IMAGE or not image.is_file():
        raise ValueError("Expected the device-specific SquashFS sysupgrade image")
    size = image.stat().st_size
    if size < 1024 * 1024 or size > 128 * 1024 * 1024:
        raise ValueError("Firmware image is empty or outside the supported size range")
    digest = hashlib.sha256()
    with image.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return {**build, "image": {"name": image.name, "size": size, "sha256": digest.hexdigest()}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    ident = sub.add_parser("identity")
    ident.add_argument("--repository-root", type=Path, required=True)
    ident.add_argument("--version")
    ident.add_argument("--output", type=Path, required=True)
    release = sub.add_parser("manifest")
    release.add_argument("--identity", type=Path, required=True)
    release.add_argument("--image", type=Path, required=True)
    release.add_argument("--version", required=True)
    release.add_argument("--source-sha", required=True)
    release.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        data = identity(args.repository_root, args.version) if args.command == "identity" else manifest(
            json.loads(args.identity.read_text()), args.image, args.version, args.source_sha)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(data, indent=2) + "\n")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Mega release metadata error: {error}\n")


if __name__ == "__main__":
    main()
