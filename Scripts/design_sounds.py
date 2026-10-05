#!/usr/bin/env python3
"""Render Voice's original felt/glass earcons. No samples or system sounds."""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 48000
ROOT = Path(__file__).resolve().parent.parent / 'Assets' / 'Sounds'


def render(name, length, notes):
    frames = round(length * RATE)
    left, right = [0.0] * frames, [0.0] * frames
    rng = random.Random(7421)
    for onset, frequency, weight, decay, pan in notes:
        for i in range(int(onset * RATE), frames):
            t = i / RATE - onset
            # Rounded attack, fast felt transient, and a small glass-like upper bloom.
            attack = (1 - math.exp(-t / 0.009)) ** 2
            envelope = attack * math.exp(-t / decay)
            phase = 2 * math.pi * frequency * t
            modulation = 0.17 * math.exp(-t / 0.028) * math.sin(phase * 1.997)
            fundamental = math.sin(phase + modulation)
            body = 0.19 * math.exp(-t / 0.095) * math.sin(phase * 2.002 + 0.25)
            sheen = 0.055 * math.exp(-t / 0.060) * math.sin(phase * 3.008 + 0.6)
            air = 0.005 * rng.uniform(-1, 1) * math.exp(-t / 0.025)
            sample = weight * envelope * (fundamental + body + sheen + air)
            left[i] += sample * (1 - pan)
            right[i] += sample * (1 + pan)
    # A tiny diffuse room tail, rather than an obvious delay or long notification ring.
    for channel in (left, right):
        dry = channel[:]
        for delay, gain in ((0.031, 0.09), (0.061, 0.055), (0.097, 0.028)):
            offset = int(delay * RATE)
            for i in range(offset, frames):
                channel[i] += dry[i - offset] * gain
    # End in actual silence; no truncation click or lingering tail.
    for i in range(frames):
        t = i / RATE
        fade = min(1.0, max(0.0, (length - t) / 0.055))
        fade = fade * fade * (3 - 2 * fade)
        left[i] *= fade
        right[i] *= fade
    peak = max(max(map(abs, left)), max(map(abs, right)))
    scale = 10 ** (-12 / 20) / peak
    pcm = bytearray()
    for l, r in zip(left, right):
        pcm.extend(struct.pack('<hh', round(l * scale * 32767), round(r * scale * 32767)))
    ROOT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(ROOT / (name + '.wav')), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(pcm)
    rms = math.sqrt(sum((v * scale) ** 2 for v in left + right) / (2 * frames))
    print(f'{name}: {length:.2f}s, peak -12 dBFS, RMS {20 * math.log10(rms):.1f} dBFS')


if __name__ == '__main__':
    # Start opens a D/A interval; finish has its own rising, three-note cadence.
    render('record-start', 0.36, [(0.0, 587.3295, 1.0, 0.071, -0.045), (0.092, 880.0, 0.78, 0.082, 0.045)])
    # A4 -> F#5 -> D6: a small lift landing on the tonic, not a reversed start.
    # Quiet lower D/A support blooms with the final note to make the arrival feel full.
    render('record-finish', 0.58, [
        (0.000, 440.0, 0.65, 0.052, -0.035),
        (0.087, 739.9888, 0.76, 0.059, 0.020),
        (0.180, 1174.6591, 0.88, 0.108, 0.035),
        (0.184, 587.3295, 0.32, 0.115, -0.020),
        (0.188, 440.0, 0.12, 0.105, 0.000),
    ])
