"""Validate a built Flutter split APK and create versioned release artifacts."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_AAPT = Path(r"D:\AndroidSdk\build-tools\36.0.0\aapt.exe")
# FlutterPluginConstants.ABI_VERSION: ARM32=1, ARM64=2, x86_64=4.
ABI_VERSION_OFFSETS = {"armeabi-v7a": 1000, "arm64-v8a": 2000, "x86_64": 4000}


def read_version(pubspec: Path) -> tuple[str, int]:
    """Read the top-level Flutter version without a YAML dependency."""
    match = re.search(
        r"^version:\s*['\"]?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\+(\d+)['\"]?\s*(?:#.*)?$",
        pubspec.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise ValueError("pubspec.yaml must contain version: <version>+<build number>")
    return match.group(1), int(match.group(2))


def inspect_apk(apk: Path, aapt: Path) -> dict:
    """Read the actual APK manifest and native ABI using Android's aapt."""
    if not apk.is_file():
        raise ValueError(f"APK does not exist: {apk}")
    if not aapt.is_file():
        raise ValueError(f"aapt does not exist: {aapt}")
    result = subprocess.run(
        [str(aapt), "dump", "badging", str(apk)],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode:
        raise ValueError(f"aapt could not inspect APK: {result.stderr.strip()}")

    package = re.search(r"^package: (.+)$", result.stdout, re.MULTILINE)
    native = re.search(r"^native-code:\s*(.+)$", result.stdout, re.MULTILINE)
    if not package or not native:
        raise ValueError("aapt did not report the APK package and native ABI")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package.group(1)))
    abis = re.findall(r"'([^']*)'", native.group(1))
    if len(abis) != 1 or abis[0] not in ABI_VERSION_OFFSETS:
        raise ValueError(f"Expected one supported split APK ABI; found {abis}")
    if not all(key in fields for key in ("name", "versionName", "versionCode")):
        raise ValueError("aapt did not report the APK version")
    try:
        version_code = int(fields["versionCode"])
    except ValueError as error:
        raise ValueError("APK versionCode is not an integer") from error
    return {
        "package_name": fields["name"],
        "version": fields["versionName"],
        "version_code": version_code,
        "abi": abis[0],
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_sidecar(path: Path, content: bytes) -> None:
    try:
        with path.open("xb") as output:
            output.write(content)
    except FileExistsError:
        if path.read_bytes() != content:
            raise ValueError(f"Refusing to overwrite different content: {path}")


def package_release(project_root: Path, apk: Path, aapt: Path) -> dict:
    version, build_number = read_version(project_root / "pubspec.yaml")
    details = inspect_apk(apk, aapt)
    expected_code = ABI_VERSION_OFFSETS[details["abi"]] + build_number
    if details["version"] != version:
        raise ValueError(
            f"APK versionName {details['version']} does not match pubspec version {version}"
        )
    if details["version_code"] != expected_code:
        raise ValueError(
            f"APK versionCode {details['version_code']} does not match "
            f"{details['abi']} split versionCode {expected_code} for build {build_number}"
        )

    filename = f"xiangshao-english-reader-v{version}-build{build_number}-{details['abi']}.apk"
    release_dir = project_root / "build" / "releases" / f"v{version}"
    destination = release_dir / filename
    checksum = sha256_file(apk)
    metadata = {
        **details,
        "build_number": build_number,
        "filename": filename,
        "size_bytes": apk.stat().st_size,
        "sha256": checksum,
    }
    sidecars = {
        destination.with_suffix(".apk.sha256"): f"{checksum}  {filename}\n".encode("ascii"),
        destination.with_suffix(".json"): (json.dumps(metadata, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    }
    # Check every existing artifact before writing any release files.
    if destination.exists() and sha256_file(destination) != checksum:
        raise ValueError(f"Refusing to overwrite different content: {destination}")
    for path, content in sidecars.items():
        if path.exists() and path.read_bytes() != content:
            raise ValueError(f"Refusing to overwrite different content: {path}")

    release_dir.mkdir(parents=True, exist_ok=True)
    try:
        with destination.open("xb") as output, apk.open("rb") as source:
            shutil.copyfileobj(source, output)
    except FileExistsError:
        if sha256_file(destination) != checksum:
            raise ValueError(f"Refusing to overwrite different content: {destination}")
    if sha256_file(destination) != checksum:
        raise ValueError("APK changed during packaging; release checksum does not match")
    for path, content in sidecars.items():
        write_sidecar(path, content)
    return metadata


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--apk", type=Path,
        default=PROJECT_ROOT / "build" / "app" / "outputs" / "flutter-apk" / "app-arm64-v8a-release.apk",
        help="Built split APK to validate and copy (default: current ARM64 release).",
    )
    parser.add_argument("--aapt", type=Path, default=DEFAULT_AAPT, help="Path to Android SDK aapt.")
    args = parser.parse_args()
    try:
        metadata = package_release(PROJECT_ROOT, args.apk.resolve(), args.aapt.resolve())
    except (OSError, ValueError) as error:
        print(f"Release packaging failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(metadata, indent=2, sort_keys=True))
    print(f"Release directory: {PROJECT_ROOT / 'build' / 'releases' / ('v' + metadata['version'])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
