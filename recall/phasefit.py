#!/usr/bin/env python3
"""Does the phase help to read the EQ knobs? Experiment on two raw recallcap captures of the same channel.

  phasefit.py REF LIVE [CH]     REF = EQ IN up (bypassed), LIVE = EQ IN pressed with the knobs to read.

The ratio LIVE / REF of the complex transfer functions is the EQ alone (the path of the card cancels). The two recordings do not start at
the same point of the noise period, which turns the phase by a pure delay: it is estimated as a whole number of samples and removed.
Then the four-section model (HF/LF shelves, two bells) is fitted on the magnitude alone and on magnitude + phase, and both are printed.
"""
import sys, json, numpy as np
from scipy.optimize import least_squares

GRID = (lambda f: f[f <= 20000])(20.0 * 2 ** (np.arange(0, 121) / 12.0))

def spectrum(base, ch, skip_s=1.5):
    meta = json.load(open(base + ".json"))
    L, rate = meta["L"], meta["rate"]
    y = np.fromfile(base + ".in.f32", dtype="<f4").reshape(-1, 32).astype(np.float64)[:, ch - 1]
    x = np.fromfile(base + ".x.f32", dtype="<f4").reshape(len(meta["channels"]), L).astype(np.float64)[meta["channels"].index(ch)]
    start = int(skip_s * rate); K = (len(y) - start) // L
    Y = np.fft.rfft(y[start:start + K * L].reshape(K, L), axis=1)
    X = np.fft.rfft(x)
    ok = np.abs(X) > np.abs(X).max() * 1e-4
    H = (Y / np.where(ok, X, 1)).mean(axis=0)
    return H, ok, L, rate, K

def ratio(ref, live, ch):
    Hr, okr, L, rate, Kr = spectrum(ref, ch); Hl, okl, _, _, Kl = spectrum(live, ch)
    ok = okr & okl & (np.abs(Hr) > 1e-9)
    R = np.where(ok, Hl / np.where(ok, Hr, 1), 0)
    r = np.fft.irfft(R, n=L)                           # impulse response of the ratio: its peak sits at the delay between the two recordings
    s = int(np.argmax(np.abs(r))); s = s - L if s > L // 2 else s
    b = np.arange(len(R))
    Rc = R * np.exp(2j * np.pi * b * s / L)
    return Rc, ok, L, rate, s, (Kr, Kl)

def to_grid(Rc, ok, L, rate):
    f = np.fft.rfftfreq(L, 1.0 / rate)
    mag, ph, fg = [], [], []
    for fc in GRID:
        sel = ok & (f >= fc / 2 ** (1 / 24)) & (f < fc * 2 ** (1 / 24))
        if sel.sum() == 0: continue
        fg.append(fc); mag.append(20 * np.log10(np.sqrt(np.mean(np.abs(Rc[sel]) ** 2)) + 1e-12))
        ph.append(np.degrees(np.angle(np.mean(Rc[sel]))))
    return np.array(fg), np.array(mag), np.array(ph)

# ---- model (analogue, minimum phase) ----
def lows(g, s, fc=60.0):
    G = 10 ** (g / 20); w0 = 2 * np.pi * fc; return (s + G * w0) / (s + w0)
def highs(g, s, fc=12000.0):
    G = 10 ** (g / 20); w0 = 2 * np.pi * fc; return (G * s + w0) / (s + w0)
def bell(g, F, q, s):
    G = 10 ** (g / 20); w0 = 2 * np.pi * F; return (s * s + s * G * w0 / q + w0 * w0) / (s * s + s * w0 / q + w0 * w0)
def H(p, f):
    s = 2j * np.pi * f
    return lows(p[0], s) * highs(p[1], s) * bell(p[2], 10 ** p[3], p[4], s) * bell(p[5], 10 ** p[6], p[7], s)

LO = [-16.7, -16.7, -16.7, np.log10(18), 0.7, -16.7, np.log10(400), 0.7]
HI = [16.7, 16.7, 16.7, np.log10(1000), 6.5, 16.7, np.log10(18000), 6.5]

def fit(f, mag, ph, use_phase, sm=0.25, sp=3.0):
    def res(p):
        h = H(p, f)
        r = [(20 * np.log10(np.abs(h)) - mag) / sm]
        if use_phase:
            d = np.degrees(np.angle(h * np.exp(-1j * np.radians(ph))))   # wrapped phase difference
            r.append(d / sp)
        return np.concatenate(r)
    best = None
    for a in (40, 120, 300, 700):
        for b in (600, 1500, 3500, 8000, 14000):
            p0 = [0, 0, 0, np.log10(a), 1.5, 0, np.log10(b), 1.5]
            r = least_squares(res, p0, bounds=(LO, HI))
            if best is None or r.cost < best.cost: best = r
    return best.x

def show(tag, p, f, mag, ph):
    h = H(p, f)
    em = 20 * np.log10(np.abs(h)) - mag
    ep = np.degrees(np.angle(h * np.exp(-1j * np.radians(ph))))
    print(f"{tag:14s} LF {p[0]:+5.1f}  HF {p[1]:+5.1f}  LM {p[2]:+5.1f} dB @{10**p[3]:5.0f} Hz Q{p[4]:.2f}  HM {p[5]:+5.1f} dB @{10**p[6]:5.0f} Hz Q{p[7]:.2f}"
          f"   rms mag {np.sqrt((em**2).mean()):.2f} dB  rms phase {np.sqrt((ep**2).mean()):.1f} deg")

if __name__ == "__main__":
    ref, live = sys.argv[1], sys.argv[2]; ch = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    Rc, ok, L, rate, s, K = ratio(ref, live, ch)
    f, mag, ph = to_grid(Rc, ok, L, rate)
    print(f"periods used (ref, live) {K}, delay between the two recordings {s} samples")
    idx = np.arange(0, len(f), 10)
    print("freq ", np.round(f[idx]).astype(int)); print("mag  ", np.round(mag[idx], 1)); print("phase", np.round(ph[idx], 0))
    pm = fit(f, mag, ph, False); pp = fit(f, mag, ph, True)
    show("magnitude only", pm, f, mag, ph)
    show("mag + phase", pp, f, mag, ph)
