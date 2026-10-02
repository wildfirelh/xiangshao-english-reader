#!/usr/bin/env python3
"""Convert textbook PNGs to quality-85 WebP, update JSON, then remove originals."""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from PIL import Image, features

PROJECT_ROOT = Path(__file__).resolve().parents[1]


def compress_images(book_dir: Path, project_root: Path = PROJECT_ROOT) -> dict:
    root = project_root.resolve()
    book_dir = book_dir.resolve()
    book_dir.relative_to(root / "assets")
    images = (book_dir / "images").resolve()
    images.relative_to(book_dir)
    manifest_path = book_dir / "book.json"
    original_manifest = manifest_path.read_bytes()
    manifest = json.loads(original_manifest.decode("utf-8"))
    updated = copy.deepcopy(manifest)
    if not features.check("webp"):
        raise RuntimeError("Pillow was installed without WebP support")

    pngs = sorted(path for path in images.iterdir() if path.suffix.lower() == ".png")
    for source in pngs:
        if source.is_symlink() or not source.is_file() or source.resolve().parent != images:
            raise ValueError(f"Refusing an unexpected image path: {source}")
        if source.with_suffix(".webp").is_symlink():
            raise ValueError(f"Refusing a symlink destination: {source}")

    staging = root / ".asset-cache" / "webp-conversion"
    staging.mkdir(parents=True, exist_ok=True)
    before = sum(path.stat().st_size for path in pngs)
    conversions = []
    # Validate every conversion before changing the manifest or deleting a PNG.
    for source in pngs:
        temporary = staging / source.with_suffix(".webp").name
        with Image.open(source) as image:
            size = image.size
            mode = "RGBA" if "A" in image.getbands() or "transparency" in image.info else "RGB"
            image.convert(mode).save(temporary, "WEBP", quality=85, method=6)
        with Image.open(temporary) as decoded:
            decoded.load()
            if decoded.format != "WEBP" or decoded.size != size:
                raise ValueError(f"WebP verification failed: {source}")
        conversions.append((source, temporary, source.with_suffix(".webp")))

    converted_paths = {source: target for source, _, target in conversions}
    for page in updated["pages"]:
        source = (root / page["imagePath"]).resolve()
        if source.suffix.lower() != ".png":
            continue
        if source.parent != images:
            raise ValueError(f"Manifest image is outside the textbook image directory: {source}")
        target = source.with_suffix(".webp")
        if source not in converted_paths:
            # Supports restarting after a successful manifest conversion or a
            # partially completed cleanup; never point to a nonexistent file.
            with Image.open(target) as decoded:
                decoded.load()
                if decoded.format != "WEBP":
                    raise ValueError(f"Invalid existing WebP: {target}")
        page["imagePath"] = target.relative_to(root).as_posix()

    for _, temporary, target in conversions:
        temporary.replace(target)
    if updated != manifest:
        (staging / "book.before-webp.json").write_bytes(original_manifest)
        temporary_manifest = staging / "book.webp.json"
        temporary_manifest.write_text(json.dumps(updated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        temporary_manifest.replace(manifest_path)

    after = sum(target.stat().st_size for _, _, target in conversions)
    for source, _, target in conversions:
        # Delete only this explicitly enumerated PNG, after both WebP and JSON
        # have been published. No recursive deletion or computed root deletion.
        if source.resolve().parent != images or source.is_symlink() or not target.is_file():
            raise ValueError(f"Unsafe cleanup path: {source}")
        source.unlink()

    report = {
        "converted": len(conversions), "quality": 85,
        "before_bytes": before, "after_bytes": after,
        "before_mib": round(before / 1024 ** 2, 2),
        "after_mib": round(after / 1024 ** 2, 2),
        "reduction_percent": round((1 - after / before) * 100, 2) if before else 0,
        "remaining_pngs": len(list(images.glob("*.png"))),
    }
    if conversions:
        (staging / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--book-dir", type=Path,
                        default=PROJECT_ROOT / "assets/textbooks/xiangshao_3_1")
    args = parser.parse_args()
    print(json.dumps(compress_images(args.book_dir), indent=2))


if __name__ == "__main__":
    main()
