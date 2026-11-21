"""Extract SHA-pinned inputs and select the report files for encryption."""

import hashlib
import json
import os
from pathlib import Path
import sys
from urllib.request import urlopen
from zipfile import ZIP_DEFLATED, ZipFile


FRAME_REPORTS = tuple(f"{variant}-{kind}.json" for variant in ("M2", "After") for kind in ("frames", "verdict"))


def unpack(archive, destination):
    with ZipFile(archive) as package:
        package.extractall(destination)


def download(variable, expected_sha256, destination, archive):
    digest = hashlib.sha256()
    with urlopen(os.environ[variable], timeout=45) as reply, archive.open("xb") as out:
        while block := reply.read(1024 * 1024):
            digest.update(block)
            out.write(block)
    if digest.hexdigest() != expected_sha256.lower():
        raise ValueError("archive-sha256-mismatch")
    unpack(archive, destination)


def bundle(mode, reports, destination):
    filenames = ("M2-iOS-result.json",) if mode == "replay" else FRAME_REPORTS
    files = []
    for name in filenames:
        file = reports / name
        if file.is_file() and not file.is_symlink() and isinstance(json.loads(file.read_bytes()), dict):
            files.append(file)
    if not files:
        raise ValueError("missing-numeric-reports")
    with ZipFile(destination, "x", ZIP_DEFLATED) as package:
        for file in files:
            package.write(file, file.name)


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    if command == "fetch":
        variable, digest, destination, archive = args
        download(variable, digest, Path(destination), Path(archive))
    elif command == "bundle":
        mode, reports, archive = args
        bundle(mode, Path(reports), Path(archive))
    else:
        raise SystemExit(2)
