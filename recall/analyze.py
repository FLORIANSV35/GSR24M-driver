#!/usr/bin/env python3
"""Analysis of console EQ captures made with recallcap (periodic pink noise through the card).

  analyze.py curves BASE            -> BASE.curves.json (EQ curve of every captured channel, dB per 1/12 octave, with its uncertainty)
  analyze.py compare A B [tol]      -> deviation between two captures per channel and per band (default tolerance 0.2 dB)
  analyze.py selftest               -> checks the method on a synthetic EQ (no hardware)

The noise is periodic (period L samples), so one period of the recording is an exact DFT frame: |Y(f)| / |X(f)| is the magnitude of the
channel's transfer function without leakage, whatever the delay of the path. Complex averaging over periods lowers the noise.
"""
import json, sys, numpy as np

BANDS = [("LF", 20, 150), ("LMF", 150, 1500), ("HMF", 1500, 8000), ("HF", 8000, 20000)]

def third_twelfth_octave_grid():
    f = 20.0 * 2 ** (np.arange(0, 121) / 12.0)   # 20 Hz .. ~20.5 kHz
    return f[f <= 20000]

def load(base):
    meta = json.load(open(base + ".json"))
    y = np.fromfile(base + ".in.f32", dtype="<f4").reshape(-1, 32).astype(np.float64)
    x = np.fromfile(base + ".x.f32", dtype="<f4").reshape(len(meta["channels"]), meta["L"]).astype(np.float64)
    return meta, y, x

def curve_for(y, x, rate, L, skip_s=1.5):
    start = int(skip_s * rate)
    K = (len(y) - start) // L
    if K < 2: raise ValueError("recording too short")
    frames = y[start:start + K * L].reshape(K, L)
    Y = np.fft.rfft(frames, axis=1)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(L, 1.0 / rate)
    ok = np.abs(X) > np.abs(X).max() * 1e-4          # bins where the noise really has energy
    Hk = Y / np.where(ok, X, 1)                      # complex transfer per period (circular shift = phase only)
    Hm = Hk.mean(axis=0)                             # complex average over periods
    mag = np.abs(Hm)
    grid = third_twelfth_octave_grid()
    out_db, out_err = [], []
    for fc in grid:
        lo, hi = fc / 2 ** (1 / 24), fc * 2 ** (1 / 24)
        sel = ok & (f >= lo) & (f < hi)
        if sel.sum() == 0: out_db.append(None); out_err.append(None); continue
        # power average inside the band, uncertainty from the spread between periods
        per = np.sqrt(np.mean(np.abs(Hk[:, sel]) ** 2, axis=1))
        m = np.sqrt(np.mean(mag[sel] ** 2))
        out_db.append(float(20 * np.log10(m + 1e-12)))
        out_err.append(float(20 * np.log10((per.mean() + per.std() / np.sqrt(K)) / per.mean())) if K > 1 else None)
    return grid.tolist(), out_db, out_err

def cmd_curves(base):
    meta, y, x = load(base)
    res = {"rate": meta["rate"], "level": meta["level"], "channels": {}}
    for i, ch in enumerate(meta["channels"]):
        g, db, er = curve_for(y[:, ch - 1], x[i], meta["rate"], meta["L"])
        res["channels"][str(ch)] = {"freq": g, "db": db, "err": er}
    json.dump(res, open(base + ".curves.json", "w"))
    print("curves written for channels", meta["channels"])
    return res

def deviation(a, b):
    fa, da = np.array(a["freq"]), np.array([np.nan if v is None else v for v in a["db"]])
    db_ = np.array([np.nan if v is None else v for v in b["db"]])
    d = db_ - da
    return fa, d

def cmd_compare(pa, pb, tol=0.2):
    a = json.load(open(pa + ".curves.json")); b = json.load(open(pb + ".curves.json"))
    allok = True
    for ch in a["channels"]:
        if ch not in b["channels"]: continue
        fa, d = deviation(a["channels"][ch], b["channels"][ch])
        d = d - np.nanmedian(d) * 0                     # no gain removal: the level is part of what is recalled
        worst = np.nanmax(np.abs(d)); line = []
        for name, lo, hi in BANDS:
            sel = (fa >= lo) & (fa < hi)
            line.append("%s %+.2f" % (name, d[sel][np.nanargmax(np.abs(d[sel]))] if sel.any() else 0))
        ok = worst <= tol; allok &= ok
        print("channel %2s: max %.2f dB %s  [%s]" % (ch, worst, "OK " if ok else "OUT", "  ".join(line)))
    print("ALL WITHIN %.1f dB" % tol if allok else "SOME CHANNELS DIFFER BY MORE THAN %.1f dB" % tol)
    return allok

def selftest():
    # synthetic console: peaking EQ at 1 kHz +6 dB (Q 1.5) and a high shelf -4 dB, noise floor -90 dB, delay 3.3 ms
    from math import pi
    rate, L = 48000, 65536
    rng = np.random.default_rng(1)
    X = np.zeros(L // 2 + 1, complex); f = np.fft.rfftfreq(L, 1 / rate)
    sel = (f > 10) & (f < 21000)
    X[sel] = f[sel] ** -0.5 * np.exp(1j * rng.uniform(0, 2 * pi, sel.sum()))
    x = np.fft.irfft(X); x *= 10 ** (-36 / 20) / x.std()
    def peaking(f0, g, q, fs):
        A = 10 ** (g / 40); w = 2 * pi * f0 / fs; al = np.sin(w) / (2 * q)
        b = np.array([1 + al * A, -2 * np.cos(w), 1 - al * A]); a = np.array([1 + al / A, -2 * np.cos(w), 1 - al / A]); return b / a[0], a / a[0]
    def shelf(f0, g, fs):
        A = 10 ** (g / 40); w = 2 * pi * f0 / fs; al = np.sin(w) / 2 * np.sqrt(2)
        c = np.cos(w); sq = 2 * np.sqrt(A) * al
        b = np.array([A * ((A + 1) + (A - 1) * c + sq), -2 * A * ((A - 1) + (A + 1) * c), A * ((A + 1) + (A - 1) * c - sq)])
        a = np.array([(A + 1) - (A - 1) * c + sq, 2 * ((A - 1) - (A + 1) * c), (A + 1) - (A - 1) * c - sq]); return b / a[0], a / a[0]
    def freqz(b, a, ff): z = np.exp(-2j * pi * ff / rate); return (b[0] + b[1] * z + b[2] * z ** 2) / (a[0] + a[1] * z + a[2] * z ** 2)
    pb, pa = peaking(1000, 6, 1.5, rate); sb, sa = shelf(8000, -4, rate)
    H = freqz(pb, pa, f) * freqz(sb, sa, f) * np.exp(-2j * pi * f * 0.0033)
    n = 12 * L
    xx = np.tile(x, n // L + 1)[:n]
    # steady state output of the periodic input = circular filtering by H
    yp = np.fft.irfft(np.fft.rfft(x) * H)
    y = np.tile(yp, n // L + 1)[:n] + rng.normal(0, 10 ** (-90 / 20), n)
    g, db, er = curve_for(y, x, rate, L, skip_s=0.5)
    truth = 20 * np.log10(np.abs(freqz(pb, pa, np.array(g)) * freqz(sb, sa, np.array(g))))
    err = np.array([abs(a - b) if a is not None else 0 for a, b in zip(db, truth)])
    print("synthetic EQ: worst error %.3f dB over %d points (1 kHz bump %.2f dB measured, 6.00 true)" % (err.max(), len(g), db[int(np.argmin(abs(np.array(g) - 1000)))]))
    assert err.max() < 0.1, "method error too large"
    print("selftest OK")

if __name__ == "__main__":
    c = sys.argv[1] if len(sys.argv) > 1 else ""
    if c == "curves": cmd_curves(sys.argv[2])
    elif c == "compare": sys.exit(0 if cmd_compare(sys.argv[2], sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0.2) else 1)
    elif c == "selftest": selftest()
    else: print(__doc__)
