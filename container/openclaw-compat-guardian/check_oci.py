#!/usr/bin/env python3
"""Validate an OCI archive without executing either platform image."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import tarfile
from datetime import datetime, timezone
from typing import Any

EXPECTED = {("linux", "amd64"), ("linux", "arm64")}
DEFAULT_MAX_COMPRESSED_MB = 180


def read_member(archive: tarfile.TarFile, name: str) -> bytes:
    member = archive.getmember(name)
    handle = archive.extractfile(member)
    if handle is None:
        raise RuntimeError(f"archive member unreadable: {name}")
    return handle.read()


def blob_name(digest: str) -> str:
    algorithm, value = digest.split(":", 1)
    if algorithm != "sha256" or len(value) != 64:
        raise RuntimeError(f"unsupported digest: {digest}")
    return f"blobs/sha256/{value}"


def load_json(archive: tarfile.TarFile, name: str) -> dict[str, Any]:
    value = json.loads(read_member(archive, name))
    if not isinstance(value, dict):
        raise RuntimeError(f"JSON object required: {name}")
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive")
    parser.add_argument("--max-compressed-mb", type=int, default=DEFAULT_MAX_COMPRESSED_MB)
    parser.add_argument("--receipt", default="oci-compatibility-receipt.json")
    args = parser.parse_args()

    archive_path = pathlib.Path(args.archive)
    archive_sha = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    max_bytes = args.max_compressed_mb * 1024 * 1024

    with tarfile.open(archive_path, "r:*") as archive:
        index = load_json(archive, "index.json")
        descriptors = index.get("manifests")
        if not isinstance(descriptors, list):
            raise RuntimeError("OCI index manifests missing")

        platforms: dict[tuple[str, str], dict[str, Any]] = {}
        for descriptor in descriptors:
            if not isinstance(descriptor, dict):
                continue
            platform = descriptor.get("platform")
            if not isinstance(platform, dict):
                continue
            os_name = platform.get("os")
            architecture = platform.get("architecture")
            if not isinstance(os_name, str) or not isinstance(architecture, str):
                continue
            key = (os_name, architecture)
            if key not in EXPECTED:
                raise RuntimeError(f"unexpected OCI platform: {key}")
            manifest = load_json(archive, blob_name(str(descriptor.get("digest"))))
            layers = manifest.get("layers")
            config = manifest.get("config")
            if not isinstance(layers, list) or not isinstance(config, dict):
                raise RuntimeError(f"invalid image manifest for {key}")
            compressed = int(config.get("size", 0)) + sum(
                int(layer.get("size", 0))
                for layer in layers
                if isinstance(layer, dict)
            )
            if compressed <= 0 or compressed > max_bytes:
                raise RuntimeError(
                    f"compressed image size out of policy for {key}: {compressed}"
                )
            platforms[key] = {
                "manifest_digest": descriptor.get("digest"),
                "compressed_bytes": compressed,
                "compressed_mb": round(compressed / (1024 * 1024), 2),
                "layer_count": len(layers),
            }

    missing = EXPECTED.difference(platforms)
    if missing:
        raise RuntimeError(f"missing OCI platforms: {sorted(missing)}")

    receipt = {
        "schema_version": 1,
        "result": "pass",
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "archive_sha256": archive_sha,
        "archive_bytes": archive_path.stat().st_size,
        "expected_platforms": ["linux/amd64", "linux/arm64"],
        "platforms": {
            f"{os_name}/{arch}": platforms[(os_name, arch)]
            for os_name, arch in sorted(platforms)
        },
        "maximum_compressed_mb_per_platform": args.max_compressed_mb,
        "windows_image_present": False,
        "unsupported_architecture_present": False,
        "provider_secret_included": False,
        "secret_values_included": False,
    }
    pathlib.Path(args.receipt).write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(receipt, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
