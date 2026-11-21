"""Seconds-domain linear BPM integration and denominator-beat prediction."""

from bisect import bisect_right
from math import ceil, isfinite, sqrt


class Grid:
    def __init__(self, points):
        self.points = points
        self.times = [p["time"] for p in points]
        if not points or self.times[0] != 0 or sorted(set(self.times)) != self.times:
            raise ValueError("Tempo times must increase from zero")
        self.quarters = [0.0]
        for i, p in enumerate(points):
            if (
                p["shape"] not in (0, 1)
                or not isfinite(p["time"])
                or not isfinite(p["bpm"])
                or p["bpm"] <= 0
            ):
                raise ValueError("Unsupported tempo point")
            if i:
                dt = self.times[i] - self.times[i - 1]
                self.quarters.append(self.quarters[-1] + self.area(i - 1, dt))

    def slope(self, i):
        p = self.points[i]
        if p["shape"] or i + 1 == len(self.times):
            return 0.0
        return (self.points[i + 1]["bpm"] - p["bpm"]) / (self.times[i + 1] - p["time"])

    def area(self, i, dt):
        return dt * (self.points[i]["bpm"] + 0.5 * self.slope(i) * dt) / 60

    def at(self, t):
        i = bisect_right(self.times, t) - 1
        dt = t - self.times[i]
        return self.points[i]["bpm"] + self.slope(i) * dt, self.points[i]["shape"]

    def quarter(self, t):
        i = bisect_right(self.times, t) - 1
        return self.quarters[i] + self.area(i, t - self.times[i])

    def seconds(self, q):
        i = bisect_right(self.quarters, q) - 1
        a = 60 * (q - self.quarters[i])
        b = self.points[i]["bpm"]
        return self.times[i] + 2 * a / (b + sqrt(max(0, b * b + 2 * self.slope(i) * a)))

    def clicks(self, start, end, meters):
        result = []
        for i, m in enumerate(meters):
            lo = max(start, m["time"])
            hi = min(end, meters[i + 1]["time"] if i + 1 < len(meters) else end)
            if lo >= hi:
                continue
            origin = self.quarter(m["time"])
            unit = 4 / m["denominator"]
            first = max(0, ceil((self.quarter(lo) - origin) / unit - 1e-8))
            last = ceil((self.quarter(hi) - origin) / unit - 1e-8)
            for n in range(first, last):
                result.append(
                    {
                        "time": int(
                            (self.seconds(origin + n * unit) - start) * 1000 + 0.5
                        ),
                        "beat": 1 + n % m["numerator"],
                    }
                )
        return result
