#!/usr/bin/env python3
"""Reads the owner's Bome MIDI Translator Pro project and writes test vectors (input message, output messages) for the translators that
are active and do not depend on state, into GSRCore/Tests/GSRCoreTests/Fixtures/bome-vectors.json.

  midi/bmtp_vectors.py "PROTOOLS FLOS GSR V2022 2 V1.bmtp"

Only the bytes are kept (no names of ports, no scripts), so the fixture can live in the repository while the project file itself does not.
"""
import collections, json, os, re, sys

path = sys.argv[1] if len(sys.argv) > 1 else "PROTOOLS FLOS GSR V2022 2 V1.bmtp"
here = os.path.dirname(os.path.abspath(__file__))
out_path = os.path.join(here, "..", "GSRCore", "Tests", "GSRCoreTests", "Fixtures", "bome-vectors.json")

presets = collections.OrderedDict(); cur = None
for line in open(path, encoding="latin-1"):
    line = line.rstrip("\n")
    m = re.match(r"\[(.*)\]", line)
    if m: cur = m.group(1); presets[cur] = {}; continue
    if cur and "=" in line and not line.startswith(";"):
        k, v = line.split("=", 1); presets[cur][k] = v

def rules(preset):
    d = presets[preset]; n = 0; out = []
    while n < 3000:
        if f"Incoming{n}" in d: out.append(dict(i=n, name=d.get(f"Name{n}", ""), inc=d[f"Incoming{n}"], out=d.get(f"Outgoing{n}", ""), opt=d.get(f"Options{n}", "")))
        n += 1
    return out

def tokens(s, env):
    """Hex string with two-letter variables to bytes."""
    b = []
    for i in range(0, len(s) - 1, 2):
        t = s[i:i + 2]
        if re.fullmatch(r"[0-9A-Fa-f]{2}", t): b.append(int(t, 16))
        elif t in env: b.append(env[t])
        else: raise ValueError(f"unknown variable {t} in {s}")
    return b

def hexs(b): return " ".join(f"{x:02X}" for x in b)

def parse_in(inc, env):
    m = re.match(r"MID[12](?:MIDA\d{4}\d{4}.*?(?:Out|In|lilo))?(.*)$", inc)
    # a plain "MID1" has no port text; "MID2" is followed by a port list ending in In or lilo
    if inc.startswith("MID1"): return tokens(inc[4:], env)
    k = max(inc.rfind("lilo"), inc.rfind("In") )
    end = k + (4 if inc[k:k + 4] == "lilo" else 2)
    return tokens(inc[end:], env)

def parse_out(out, env):
    """Returns a list of (device, bytes): device 0 to 2 for a Bome virtual output, -1 for the console."""
    if out.startswith("MID1"): return [(-1, tokens(out[4:], env))]
    if not out.startswith("MID2"): return None
    res = []
    for seg in out[4:].split("MIDA")[1:]:
        k = seg.rfind("Out")
        names = seg[:k]
        devs = sorted(set(int(x) - 1 for x in re.findall(r"Translator (\d) Virtual", names)))
        res.append((devs, tokens(seg[k + 3:], env)))
    return res

vectors = []
def add(name, inc, out_, env=None):
    env = env or {}
    i = parse_in(inc, env); o = parse_out(out_, env)
    if o is None: return
    outs = []
    for dev, b in o:
        if isinstance(dev, list):
            for d in dev: outs.append({"device": d, "bytes": hexs(b)})
        else: outs.append({"device": dev, "bytes": hexs(b)})
    vectors.append({"rule": name, "in": hexs(i), "out": outs})

p0 = [r for r in rules("Preset.0") if r["opt"].startswith("Actv01")]
by = collections.defaultdict(list)
for r in p0: by[re.sub(r"\d+", "N", r["name"])].append(r)

defaults = {"no": 0x41, "nn": 0x01, "mo": 0x43, "mn": 0x03}
for r in by["Protools Tick"]: add(r["name"], r["inc"], r["out"])
for r in by["Fader N"]:
    for pp in (0, 37, 127): add(f'{r["name"]} value {pp}', r["inc"], r["out"], {"pp": pp})
for fam in ("Select N note on", "Select N note off", "Solo N note on", "Solo N note off", "Zoom Mode on", "Zoom Mode off", "Zoom Up on", "Zoom Up off",
            "Zoom Left on", "Zoom Left off", "Zoom Right on", "Zoom Right off", "Zoom Down on", "Zoom Down off", "Bank Left on", "Bank Left off",
            "Bank Right on", "Bank Right off", "Enter on", "Enter off", "Mix on but N", "Mix off but N", "Edit on but N", "Edit off but N"):
    for r in by[fam]:
        if r["name"] == "Solo 1 note off": continue            # the Bome project releases a variable that is never set (a typo); the bridge releases solo properly
        add(r["name"], r["inc"], r["out"], defaults)
for fam in ("Transport RTZ", "Transport PLAY", "Transport STOP", "Transport RTE", "Transport REC"):
    for r in by[fam]: add(r["name"], r["inc"], r["out"])
for r in by["Transport JOG"][:1]:
    for pp in (0, 5, 62, 63, 64, 100, 127): add(f"jog steps pp={pp}", r["inc"], r["out"], {"pp": pp, "qq": 66 if pp < 63 else 65, "rr": 2 if pp < 63 else 1})

# return path: the console as output, HUI as input
p1 = [r for r in rules("Preset.1") if r["opt"].startswith("Actv01")]
ret = []
for r in p1:
    n = r["name"]
    if n.startswith("Fader ") or re.match(r"Select \d+ note", n) or n.startswith("Transport ") or n.startswith("Zoom Mode LED"):
        ret.append(r)
ret_vectors = []
for r in ret:
    m = re.search(r"Translator (\d) Virtual In", r["inc"]); dev = int(m.group(1)) - 1
    end = r["inc"].rfind("In") + 2
    env = {"pp": 77, "xx": 5}
    try:
        i = tokens(r["inc"][end:], env); o = tokens(r["out"][4:], env) if r["out"].startswith("MID1") else None
    except ValueError: continue
    if o is None: continue
    ret_vectors.append({"rule": r["name"], "device": dev, "in": hexs(i), "out": hexs(o)})

os.makedirs(os.path.dirname(out_path), exist_ok=True)
json.dump({"toHUI": vectors, "toConsole": ret_vectors}, open(out_path, "w"), indent=1)
print(f"{len(vectors)} console to HUI vectors, {len(ret_vectors)} HUI to console vectors -> {os.path.normpath(out_path)}")
