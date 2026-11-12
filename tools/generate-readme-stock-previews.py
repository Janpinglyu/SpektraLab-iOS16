#!/usr/bin/env python3
"""Render README contact sheets from one camera RAW through the shipping engine."""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
sys.path.insert(0, str(ENGINE / "tests"))

from spk_ctypes import Engine, EngineError  # noqa: E402

def decode_raw(path: Path, work: Path) -> np.ndarray:
    decoder = work / "image-decoder-dump"
    dump = work / "frame.bin"
    subprocess.run([
        "xcrun", "swiftc",
        str(ROOT / "ios/SpektraLab/Import/ImageDecoder.swift"),
        str(ROOT / "ios/Tests/ImageDecoderDump/main.swift"),
        "-o", str(decoder),
        "-framework", "CoreImage", "-framework", "CoreGraphics",
        "-framework", "ImageIO", "-framework", "UniformTypeIdentifiers",
    ], check=True)
    subprocess.run([str(decoder), str(path), str(dump), "1024"], check=True)
    blob = dump.read_bytes()
    width, height = struct.unpack_from("<II", blob)
    frame = np.frombuffer(blob, dtype="<f4", offset=8)
    return np.ascontiguousarray(frame.reshape(height, width, 3))


def profile_catalog(resources: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str]], list[tuple[str, str]]]:
    films, papers, slides = [], [], []
    for path in sorted((resources / "profiles").glob("*.json")):
        data = json.loads(path.read_text())
        info = data.get("info", {})
        support = info.get("support")
        kind = info.get("type")
        if data.get("derived_from") and not support:
            support, kind = "film", "negative"
        item = (path.stem, info.get("name", path.stem))
        if info.get("stage") == "printing" or support == "paper":
            papers.append(item)
        elif support == "film" and kind == "positive":
            slides.append(item)
        elif support == "film":
            films.append(item)
    return films, papers, slides


def stage_resources(work: Path) -> Path:
    staged = work / "resources"
    shutil.copytree(ENGINE / "resources", staged)
    product = ENGINE / "resources_product"
    for profile in (product / "profiles").glob("*.json"):
        shutil.copy2(profile, staged / "profiles" / profile.name)
    shutil.copy2(ENGINE / "build" / "spektrafilm.metallib", staged / "spektrafilm.metallib")
    return staged


def render(engine: Engine, frame: np.ndarray, film: str, paper: str,
           *, scan_film: bool = False) -> Image.Image:
    delta = {
        "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
        "output_color_space": "sRGB", "output_cctf_encoding": True,
        "film_stock": film, "print_stock": paper, "auto_exposure": True,
        "auto_exposure_method": "balanced", "film_format_mm": 36.0,
        "grain_active": True, "grain_sublayers_active": True, "grain_amount": 1.0,
        "halation_active": True, "halation_amount": 1.0,
        "halation_scatter_amount": 1.0, "halation_headroom_ev": 4.0,
        "dir_couplers_active": True, "dir_couplers_amount": 1.0,
        "glare_active": True, "glare_amount": 1.0,
        "density_curve_gamma": 1.0, "filter_shift_scale": 40.0,
    }
    if scan_film:
        delta["scan_film"] = True
    with engine.open(frame, delta) as session:
        session.solve("both")
        rgba, _ = session.render("live")
    return Image.fromarray((rgba[..., :3] / 257).astype(np.uint8), "RGB")


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    path = Path("/System/Library/Fonts/Supplemental/Arial.ttf")
    return ImageFont.truetype(str(path), size) if path.exists() else ImageFont.load_default()


def sheet(title: str, items: list[tuple[str, Image.Image]], output: Path) -> None:
    portrait = bool(items and items[0][1].height > items[0][1].width)
    columns, label_h = (5, 48) if portrait else (4, 48)
    image_w, image_h = (240, 360) if portrait else (300, 200)
    rows = (len(items) + columns - 1) // columns
    canvas = Image.new("RGB", (columns * image_w, 66 + rows * (image_h + label_h)), "#f3f3f1")
    draw = ImageDraw.Draw(canvas)
    draw.text((18, 18), title, fill="#151515", font=font(25))
    label_font = font(15)
    for index, (name, image) in enumerate(items):
        x = (index % columns) * image_w
        y = 66 + (index // columns) * (image_h + label_h)
        tile = ImageOps.fit(image, (image_w, image_h), Image.Resampling.LANCZOS)
        canvas.paste(tile, (x, y))
        draw.text((x + 9, y + image_h + 10), name, fill="#202020", font=label_font)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, quality=84, optimize=True, progressive=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw", type=Path)
    parser.add_argument("--output", type=Path, default=ROOT / "docs" / "stock-previews")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="spektralab-previews-") as tmp:
        work = Path(tmp)
        frame = decode_raw(args.raw, work)
        resources = stage_resources(work)
        films, papers, slides = profile_catalog(resources)
        with Engine(library=ENGINE / "build" / "libspektrafilm_engine.dylib",
                    resources=resources) as engine:
            for paper_id, paper_name in papers:
                rendered = []
                for film_id, film_name in films:
                    try:
                        rendered.append((film_name, render(engine, frame, film_id, paper_id)))
                        print(f"rendered {film_id} + {paper_id}")
                    except EngineError as error:
                        print(f"skipped {film_id} + {paper_id}: {error}", file=sys.stderr)
                sheet(f"Paper: {paper_name}", rendered, args.output / f"{paper_id}.jpg")
            slide_items = [(name, render(engine, frame, stock, papers[0][0], scan_film=True))
                           for stock, name in slides]
            sheet("Reversal films (no paper print stage)", slide_items,
                  args.output / "reversal-films.jpg")


if __name__ == "__main__":
    main()
