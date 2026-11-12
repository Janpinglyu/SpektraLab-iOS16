#!/usr/bin/env python3
"""Render an iOS decoder dump and compare it with a Mac sRGB export."""

from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "engine"
sys.path.insert(0, str(ENGINE / "tests"))
from spk_ctypes import Engine  # noqa: E402


def stage_resources(root: Path) -> Path:
    resources = root / "resources"
    shutil.copytree(ENGINE / "resources", resources)
    for profile in (ENGINE / "resources_product" / "profiles").glob("*.json"):
        shutil.copy2(profile, resources / "profiles" / profile.name)
    shutil.copy2(ENGINE / "build" / "spektrafilm.metallib",
                 resources / "spektrafilm.metallib")
    return resources


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("frame", type=Path)
    parser.add_argument("mac", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--tier", choices=("live", "full"), default="live")
    args = parser.parse_args()

    blob = args.frame.read_bytes()
    width, height = np.frombuffer(blob[:8], dtype="<u4")
    frame = np.frombuffer(blob[8:], dtype="<f4").reshape(int(height), int(width), 3).copy()
    delta = {
        "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
        "output_color_space": "sRGB", "output_cctf_encoding": True,
        "film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura",
        "auto_exposure": True, "auto_exposure_method": "balanced",
        "film_format_mm": 36.0,
        "grain_active": True, "grain_sublayers_active": True, "grain_amount": 1.0,
        "halation_active": True, "halation_amount": 1.0,
        "halation_scatter_amount": 1.0, "halation_headroom_ev": 4.0,
        "dir_couplers_active": True, "dir_couplers_amount": 1.0,
        "glare_active": True, "glare_amount": 1.0,
        "density_curve_gamma": 1.0, "filter_shift_scale": 40.0,
    }
    with tempfile.TemporaryDirectory(prefix="spektralab-parity-") as tmp:
        resources = stage_resources(Path(tmp))
        with Engine(library=ENGINE / "build" / "libspektrafilm_engine.dylib",
                    resources=resources) as engine:
            with engine.open(frame, delta) as session:
                session.solve("both")
                rgba, _ = session.render(args.tier)

    ios = Image.fromarray((rgba[..., :3] / 257).astype(np.uint8), "RGB")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    ios.save(args.output)
    mac = Image.open(args.mac).convert("RGB").resize(ios.size, Image.Resampling.LANCZOS)
    a, b = np.asarray(ios, dtype=np.float32), np.asarray(mac, dtype=np.float32)
    error = np.abs(a - b)
    print(f"tier={args.tier} iOS={ios.size[0]}x{ios.size[1]} "
          f"Mac={Image.open(args.mac).size[0]}x{Image.open(args.mac).size[1]}")
    print(f"MAE={error.mean():.3f}/255 RMSE={np.sqrt(np.mean((a-b)**2)):.3f}/255 "
          f"P95={np.percentile(error, 95):.1f}/255 MAX={error.max():.0f}/255")
    # Grain is stochastic, so a native pixel comparison includes different
    # grain positions. A box-filtered comparison measures the underlying
    # exposure and colour independently of that random high-frequency texture.
    colour_size = (max(1, ios.width // 16), max(1, ios.height // 16))
    ios_colour = ios.resize(colour_size, Image.Resampling.BOX)
    mac_colour = mac.resize(colour_size, Image.Resampling.BOX)
    ca = np.asarray(ios_colour, dtype=np.float32)
    cb = np.asarray(mac_colour, dtype=np.float32)
    colour_error = np.abs(ca - cb)
    print(f"COLOUR_MAE={colour_error.mean():.3f}/255 "
          f"COLOUR_RMSE={np.sqrt(np.mean((ca-cb)**2)):.3f}/255 "
          f"COLOUR_P95={np.percentile(colour_error, 95):.1f}/255")
    ImageChops.difference(ios, mac).save(args.output.with_name(args.output.stem + "-diff.png"))


if __name__ == "__main__":
    main()
