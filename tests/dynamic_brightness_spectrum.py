"""Measure the native shelf/Delta fixture without assuming a brick-wall cutoff."""
import json
import math
from pathlib import Path
import sys
import wave

FREQUENCIES = (63, 125, 250, 500, 1000, 2000, 4000, 8000, 12000)


def read(path):
    with wave.open(str(path), "rb") as stream:
        assert stream.getsampwidth() == 3 and stream.getnchannels() == 2
        rate = stream.getframerate()
        data = stream.readframes(stream.getnframes())
    return rate, [int.from_bytes(data[i:i + 3], "little", signed=True)
                  for i in range(0, len(data), 3)]


def rms(values):
    return math.sqrt(sum(value * value for value in values) / len(values))


def db(ratio):
    return 20 * math.log10(ratio) if ratio > 0 else -math.inf


def analyze(directory):
    renders = {name: read(directory / f"{name}.wav")
               for name in ("dynamic", "delta", "unity")}
    rate, unity = renders["unity"]
    assert len(unity) == 18 * rate * 2, "Expected nine two-second stereo tones"
    assert all(other_rate == rate and len(samples) == len(unity)
               for other_rate, samples in renders.values()), "Render lengths/rates differ"
    error = max(abs(delta - (dynamic - dry)) for delta, dynamic, dry in zip(
        renders["delta"][1], renders["dynamic"][1], unity))
    matched = error <= 2
    print(f"{'PASS' if matched else 'FAIL'}: Delta equals processed minus dry; maximum error {error}/8388608")
    print("Frequency   Output boost   Delta / dry   Delta RMS dBFS")
    results, flags = [], []
    for segment, frequency in enumerate(FREQUENCIES):
        start = int((segment * 2 + 1.5) * rate) * 2
        end = int((segment + 1) * 2 * rate) * 2
        levels = {name: rms(samples[start:end]) for name, (_, samples) in renders.items()}
        boost = db(levels["dynamic"] / levels["unity"])
        residual = db(levels["delta"] / levels["unity"])
        delta_dbfs = db(levels["delta"] / 8388608)
        if not -0.02 <= boost <= 3.02:
            flags.append(f"{frequency} Hz output boost is {boost:+.4f} dB")
        print(f"{frequency:6} Hz    {boost:+9.4f} dB  {residual:9.3f} dB   {delta_dbfs:9.3f} dBFS")
        results.append({"frequency_hz": frequency, "output_boost_db": boost,
                        "delta_relative_dry_db": residual, "delta_rms_dbfs": delta_dbfs})
    output = {"sample_rate": rate, "delta_max_error_quantization_units": error,
              "shelf_hz": 2000, "maximum_boost_db": 3, "tones": results,
              "boost_range_flags": flags}
    (directory / "spectrum.json").write_text(json.dumps(output, indent=2) + "\n")
    print("No below-shelf silence assertion: a shelf transition and phase shift can leave a Delta residual.")
    assert matched, f"Delta differs from processed-minus-dry by {error} quantization units"
    assert not flags, "; ".join(flags)
    return output


if __name__ == "__main__":
    analyze(Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/gphil-dynamic-brightness-spectrum"))
