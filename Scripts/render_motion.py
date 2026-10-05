#!/usr/bin/env python3
"""Encode the sample-data native preview as a small README animation.

Requires Pillow (development only). Run after VoicePreview --motion.
"""
from pathlib import Path
from PIL import Image

root = Path(__file__).resolve().parent.parent
paths = sorted((root / "build/previews/motion").glob("[0-9][0-9][0-9].png"))
if len(paths) != 96:
    raise SystemExit("Expected 96 frames. Run build/VoicePreview build/previews --motion first.")
frames = []
for path in paths:
    with Image.open(path) as image:
        frames.append(image.convert("RGB").resize((760, 260), Image.Resampling.LANCZOS))
palette = frames[24].quantize(colors=128)
frames = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
destination = root / "docs/images/recording-flow.gif"
frames[0].save(destination, save_all=True, append_images=frames[1:],
               duration=[80, 80, 90] * 32, loop=0, optimize=True, disposal=1)
# A stable fallback for people who prefer a still image.
frames[24].convert("RGB").save(root / "docs/images/recording-flow.png", optimize=True)
print(f"Encoded {len(frames)} frames: {destination.name} ({destination.stat().st_size:,} bytes)")
