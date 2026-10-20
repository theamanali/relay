"""Decode precision.exe's production dump and compare numeric patch centres.

Usage: python tools/check-precision.py host/target/.../capture.hevc [...]
Needs ffmpeg/ffprobe on PATH; uses the adjacent diagnostic CSV. Output errors
are in 10-bit RGB codes, not byte values. Lossy encoding need not be exact.
"""
import argparse
import csv
import json
from pathlib import Path
import struct
import subprocess


def check(path, frame):
    meta = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)
    ]))["streams"][0]
    raw = subprocess.check_output([
        "ffmpeg", "-v", "error", "-i", str(path), "-vf",
        f"select=eq(n\\,{frame}),scale=in_color_matrix=bt601:out_range=full",
        "-frames:v", "1", "-pix_fmt", "rgb48le", "-f", "rawvideo", "-"
    ])
    width, height = meta["width"], meta["height"]
    if len(raw) != width * height * 6:
        raise ValueError(f"{path}: missing decoded frame {frame}")
    counts = [set() for _ in range(4)]
    errors, controls = [], []
    with path.with_suffix(".csv").open(newline="") as source:
        for row in csv.DictReader(source):
            x, y = int(row["x"]), int(row["y"])
            expected = [int(row[f"expected_{c}"]) for c in "rgb"]
            rgb = [round(c * 1023 / 65535) for c in struct.unpack_from(
                "<HHH", raw, (y * width + x) * 6)]
            delta = [abs(a-b) for a, b in zip(rgb, expected)]
            errors.extend(delta)
            band = int(row["band"])
            if band < 4:
                counts[band].add(rgb[min(band, 2)])
            else:
                controls.append({"patch": row["patch"], "expected": expected,
                                 "decoded": rgb, "max_error": max(delta)})
    result = {"file": str(path), "format": meta["pix_fmt"],
              "size": [width, height], "range": meta.get("color_range"),
              "matrix": meta.get("color_space"),
              "transfer": meta.get("color_transfer"),
              "primaries": meta.get("color_primaries"),
              "ramp_distinct": [len(s) for s in counts],
              "max_error": max(errors),
              "mean_absolute_error": round(sum(errors)/len(errors), 3),
              "controls": controls}
    if max(errors) > 24:
        raise ValueError(f"large SDR channel/range error: {result}")
    if [result[k] for k in ["range", "matrix", "transfer", "primaries"]] != [
            "tv", "smpte170m", "bt709", "bt709"]:
        raise ValueError(f"unexpected SDR VUI: {result}")
    path.with_suffix(".decoded.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", nargs="+", type=Path)
    parser.add_argument("--frame", type=int, default=10)
    args = parser.parse_args()
    for dump in args.dump:
        check(dump, args.frame)
