#!/usr/bin/env python
# Measures the frequency and level of the loudest part of a WAV recording (16/24/32-bit PCM, any channel count).
# Usage: python measure_freq.py recording.wav            (works with python 2.7 and python 3)
from __future__ import print_function
import sys, wave, struct, math

def read(path):
    w = wave.open(path, 'rb')
    ch, sw, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
    raw = w.readframes(n); w.close()
    return ch, sw, rate, n, raw

def samples(raw, sw, ch, c, n):
    out = []
    step = sw * ch
    for i in range(n):
        o = i * step + c * sw
        b = raw[o:o + sw]
        if sw == 2:
            v = struct.unpack('<h', b)[0] / 32768.0
        elif sw == 3:
            v = (struct.unpack('<i', b + (b'\xff' if (bytearray(b)[2] & 0x80) else b'\x00'))[0]) / 8388608.0
        else:
            v = struct.unpack('<i', b)[0] / 2147483648.0
        out.append(v)
    return out

path = sys.argv[1]
ch, sw, rate, n, raw = read(path)
print('%s: %d channels, %d-bit, %d Hz, %.1f s' % (path, ch, sw * 8, rate, n / float(rate)))
for c in range(ch):
    x = samples(raw, sw, ch, c, n)
    win = rate // 2
    best, bi = 0, 0
    for s in range(0, n - win, win):
        r = math.sqrt(sum(v * v for v in x[s:s + win]) / win)
        if r > best:
            best, bi = r, s
    if best < 1e-4:
        print('  channel %d: silent' % (c + 1)); continue
    seg = x[bi:bi + win]
    mean = sum(seg) / len(seg)
    cr = [i for i in range(1, len(seg)) if seg[i - 1] - mean < 0 <= seg[i] - mean]
    f = (len(cr) - 1) * rate / float(cr[-1] - cr[0]) if len(cr) > 10 else 0.0
    print('  channel %d: level %.1f dBFS rms, frequency %.1f Hz' % (c + 1, 20 * math.log10(best), f))
