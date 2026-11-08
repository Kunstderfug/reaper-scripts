"""Compare renders produced by native_dynamic_brightness.lua; standard library only."""
import math
from pathlib import Path
import sys
import wave


def read_samples(path):
    with wave.open(str(path), "rb") as stream:
        width = stream.getsampwidth()
        assert width == 3 and stream.getnchannels() == 2
        rate = stream.getframerate()
        data = stream.readframes(stream.getnframes())
    samples = [int.from_bytes(data[i:i + width], "little", signed=True)
               for i in range(0, len(data), width)]
    return rate, samples


def settled(samples, rate, segment):
    start = int((2 * segment + 1.5) * rate) * 2
    return samples[start:start + int(0.25 * rate) * 2]


def level(samples):
    return math.sqrt(sum(value * value for value in samples) / len(samples))


directory = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/gphil-dynamic-brightness-test")
renders = {name: read_samples(directory / f"{name}.wav")
           for name in ("unity", "dynamic", "delta", "static3")}
rate, unity_samples = renders["unity"]
assert all(other_rate == rate and len(samples) == len(unity_samples)
           for other_rate, samples in renders.values()), "Render lengths/rates differ"
# Three separately quantized 24-bit signals permit up to two integer units of
# rounding error. This checks every sample, including attacks and decays.
delta_error = max(abs(delta - (dynamic - unity)) for delta, dynamic, unity in zip(
    renders["delta"][1], renders["dynamic"][1], unity_samples))
assert delta_error <= 2, f"Delta differs from wet-minus-dry by {delta_error} quantization units"
print(f"PASS: native Delta equals dynamic minus unity (maximum error {delta_error}/8388608)")
previous = 0
for segment, input_db in enumerate((-60, -40, -30, -24, -18, -12, -6, -6, -60)):
    unity = level(settled(unity_samples, rate, segment))
    boost = 20 * math.log10(level(settled(renders["dynamic"][1], rate, segment)) / unity)
    reference = 20 * math.log10(level(settled(renders["static3"][1], rate, segment)) / unity)
    assert -0.01 <= boost <= reference + 0.01 and reference <= 3.01
    if segment in (0, 1, 2, 8):
        assert abs(boost) < 0.01, (segment, boost)
        delta_peak = max(abs(value) for value in settled(renders["delta"][1], rate, segment))
        assert delta_peak <= 2, ("Quiet Delta should be silent", segment, delta_peak)
    if segment in (3, 4, 5):
        assert boost > previous, (segment, boost, previous)
        previous = boost
    if segment in (6, 7):
        assert abs(boost - reference) < 0.01, (segment, boost, reference)
    print(f"{input_db:3} dBFS: dynamic {boost:.3f} dB; static reference {reference:.3f} dB")
print("PASS: quiet/return flat and Delta silent, progressive lift, saturation matches static +3 dB shelf")

# Low-level attenuation is measured against a native static -3 dB shelf.
extra = {name: read_samples(directory / f"{name}.wav")[1]
         for name in ("cut_boost", "cut_boost_delta", "static_cut3")}
error = max(abs(delta - (wet - dry)) for delta, wet, dry in zip(
    extra["cut_boost_delta"], extra["cut_boost"], unity_samples))
assert error <= 2, ("Bipolar Delta", error)
previous = -4
for segment, input_db in enumerate((-60, -40, -30, -24, -18, -12, -6, -6, -60)):
    dry = level(settled(unity_samples, rate, segment))
    gain = 20 * math.log10(level(settled(extra["cut_boost"], rate, segment)) / dry)
    lower = 20 * math.log10(level(settled(extra["static_cut3"], rate, segment)) / dry)
    upper = 20 * math.log10(level(settled(renders["static3"][1], rate, segment)) / dry)
    assert lower - .01 <= gain <= upper + .01, (segment, gain, lower, upper)
    if segment in (0, 1, 2, 8):
        assert abs(gain - lower) < .01, ("Full quiet cut", segment, gain, lower)
    if segment in (6, 7):
        assert abs(gain - upper) < .01, ("Full loud boost", segment, gain, upper)
    if segment in (3, 4, 5):
        assert gain > previous, ("Continuous rising gain", segment, gain, previous)
        previous = gain
    print(f"{input_db:3} dBFS: cut/boost {gain:+.3f} dB")
print("PASS: quiet cut / loud boost bounded to static -3/+3 references; bipolar Delta matches")

wide = {name: read_samples(directory / f"{name}.wav")[1]
        for name in ("wide", "wide_unity", "static12", "static_cut12")}
for i in range(9):
    dry = level(settled(wide["wide_unity"], rate, i))
    actual = 20 * math.log10(level(settled(wide["wide"], rate, i)) / dry)
    low = 20 * math.log10(level(settled(wide["static_cut12"], rate, i)) / dry)
    high = 20 * math.log10(level(settled(wide["static12"], rate, i)) / dry)
    assert low - .03 <= actual <= high + .03, (i, actual, low, high)
    if i in (0, 8):
        assert abs(actual - low) < .03, ("-12 endpoint", i, actual, low)
    if i in (6, 7):
        assert abs(actual - high) < .03, ("+12 endpoint", i, actual, high)
    print(f"Wide range segment {i}: {actual:+.3f} dB")
print("PASS: supported -12/+12 range reaches and respects native static endpoints")

restored = read_samples(directory / "post_delta_restore.wav")[1]
live_cut = read_samples(directory / "fresh_live_cut15.wav")[1]
for i in range(9):
    dry = level(settled(unity_samples, rate, i))
    prior = level(settled(renders["dynamic"][1], rate, i))
    after = level(settled(restored, rate, i))
    assert abs(20 * math.log10(after / prior)) < .001, ("Delta restore", i)
    gain = 20 * math.log10(level(settled(live_cut, rate, i)) / dry)
    assert -1.52 <= gain <= 3.01, ("Live cut limit bounds", i, gain)
    if i in (0, 1, 2, 8):
        assert abs(gain + 1.5) < .02, ("Live -1.5 cut endpoint", i, gain)
print("PASS: Delta restores normal following; live lower-limit adjustment reaches -1.5 dB")
