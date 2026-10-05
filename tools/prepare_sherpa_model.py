#!/usr/bin/env python3
"""Prepare the pinned, quantized English model; the App itself never downloads it."""
import argparse
import hashlib
import json
import lzma
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODEL = "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26"
REVISION = "672fbf1b30579d6585301139bb363f42a0ad4a24"
FILES = {
    "encoder.int8.onnx": ("encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx", 71083163,
                          "563fde436d16cf7607cf408cd6b30909819d03162652ef389c2450ced3f45ac1"),
    "decoder.onnx": ("decoder-epoch-99-avg-1-chunk-16-left-128.onnx", 2092621,
                     "7bf787f90b194b307e5a4ad6a34fadb4e748304c35f78a8d66358a05b13ee6ef"),
    "joiner.int8.onnx": ("joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx", 259335,
                         "d944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297"),
    "tokens.txt": ("tokens.txt", 5048,
                   "49e3c2646595fd907228b3c6787069658f67b17377c60aeb8619c4551b2316fb"),
}


def verified(path, size, checksum):
    if not path.is_file() or path.stat().st_size != size:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == checksum


def pack_model(target, size, checksum):
    """Bundle a lossless XZ copy; native Sherpa still reads the original ONNX."""
    packed = target.with_suffix(target.suffix + ".xz")
    valid = False
    if packed.is_file():
        try:
            digest, decoded_size = hashlib.sha256(), 0
            with lzma.open(packed, "rb") as stream:
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
                    decoded_size += len(chunk)
            valid = decoded_size == size and digest.hexdigest() == checksum
        except (OSError, EOFError, lzma.LZMAError):
            pass
    if not valid:
        partial = packed.with_suffix(packed.suffix + ".part")
        try:
            with target.open("rb") as source, lzma.open(
                partial, "wb", format=lzma.FORMAT_XZ,
                check=lzma.CHECK_CRC64, preset=6,
            ) as output:
                while chunk := source.read(1024 * 1024):
                    output.write(chunk)
            partial.replace(packed)
        finally:
            partial.unlink(missing_ok=True)
    with packed.open("rb") as stream:
        packed_hash = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"asset": packed.name, "compression": "xz",
            "assetSize": packed.stat().st_size, "assetSha256": packed_hash}


def prepare(output):
    output.mkdir(parents=True, exist_ok=True)
    metadata = {"model": MODEL, "revision": REVISION, "license": "Apache-2.0",
                "sampleRate": 16000, "modelType": "zipformer2", "files": {}}
    for filename, (source, size, checksum) in FILES.items():
        target = output / filename
        url = f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{source}"
        if not verified(target, size, checksum):
            partial = target.with_suffix(target.suffix + ".part")
            for attempt in range(3):
                try:
                    print(f"Downloading {filename} ({size:,} bytes)", flush=True)
                    with urllib.request.urlopen(url, timeout=60) as response, partial.open("wb") as stream:
                        while chunk := response.read(1024 * 1024):
                            stream.write(chunk)
                    if not verified(partial, size, checksum):
                        raise ValueError(f"Checksum mismatch: {filename}")
                    partial.replace(target)
                    break
                except (OSError, ValueError):
                    partial.unlink(missing_ok=True)
                    if attempt == 2:
                        raise
                    time.sleep(2 * (attempt + 1))
        print(f"Verified {filename}", flush=True)
        metadata["files"][filename] = {"url": url, "size": size, "sha256": checksum}
        if filename.endswith(".onnx"):
            metadata["files"][filename].update(pack_model(target, size, checksum))
            print(f"Packed {filename}: {metadata['files'][filename]['assetSize']:,} bytes", flush=True)
    (output / "model.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"Offline model ready: {sum(item[1] for item in FILES.values()):,} bytes", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "assets/models/sherpa")
    prepare(parser.parse_args().output.resolve())
