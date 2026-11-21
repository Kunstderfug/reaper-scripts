"""OPUS comparison evidence using Scoremaker's positive-peak/onset rules.

FFmpeg decodes channel zero at 48 kHz and applies the Ogg Opus pre-skip.
The detector mirrors OpusClickDataProcessor.extractClickTimes: 0.07 positive
peak qualification, 0.4 downbeat, 100 ms peak suppression, and a 20 ms
lookback for the first absolute sample above 0.02. It never shifts onsets
to make the generated grid fit. Unusual legacy levels require review.
"""
from array import array
from pathlib import Path
import subprocess
import sys


DETECTOR_VERSION = 'scoremaker-positive-peak-onset-20261119-v1'


def extract_clicks(samples, sample_rate=48000):
    if sample_rate <= 0:
        raise ValueError('Invalid sample rate')
    suppression, lookback = sample_rate // 10, sample_rate // 50
    clicks, previous, index = [], None, 0
    while index < len(samples):
        while index < len(samples) and (samples[index] < 0.07 or
                (index + 1 < len(samples) and samples[index] < samples[index + 1])):
            index += 1
        if index >= len(samples):
            break
        if previous is None or index - previous > suppression:
            last_beat = clicks[-1]['beat'] if clicks else 0
            beat = 1 if samples[index] > 0.4 else (2 if last_beat <= 1 else last_beat + 1)
            start = max(0, index - lookback, previous + suppression + 1 if previous is not None else 0)
            onset = next((n for n in range(start, index + 1) if abs(samples[n]) > 0.02), index)
            clicks.append({'time': int(onset * 1000 / sample_rate + 0.5), 'beat': beat})
            previous = index
        index += 1
    return clicks


def decode_clicks(path):
    result = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(Path(path)),
                             '-af', 'pan=mono|c0=c0', '-ar', '48000',
                             '-f', 'f32le', '-'], capture_output=True, timeout=120)
    if result.returncode:
        raise ValueError('FFmpeg could not decode OPUS reference: ' + str(path))
    samples = array('f')
    samples.frombytes(result.stdout)
    if sys.byteorder != 'little':
        samples.byteswap()
    clicks = extract_clicks(samples)
    if not clicks:
        raise ValueError('No qualified OPUS pulses: ' + str(path))
    return clicks
