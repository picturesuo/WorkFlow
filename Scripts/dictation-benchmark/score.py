"""Word error rate with a stated normalization; see normalize() and README.md."""
import json, re, sys, collections, math

UNITS = {w: i for i, w in enumerate("zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split())}
TENS = {w: 10 * i for i, w in enumerate("_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()) if w != "_"}
ORD = {"first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five", "sixth": "six", "seventh": "seven",
       "eighth": "eight", "ninth": "nine", "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve", "thirteenth": "thirteen",
       "fourteenth": "fourteen", "fifteenth": "fifteen", "twentieth": "twenty", "thirtieth": "thirty"}
SCALES = {"hundred": 100, "thousand": 1000, "million": 1_000_000}

def words_to_digits(tokens):
    out, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in UNITS or t in TENS:
            total, current, j = 0, 0, i
            last = None
            while j < len(tokens):
                w = tokens[j]
                if w in TENS and last in (None, "scale"):
                    current += TENS[w]; last = "tens"
                elif w in UNITS and (last in (None, "scale") or (last == "tens" and UNITS[w] < 10)):
                    current += UNITS[w]; last = "unit"
                elif w in SCALES and last in ("unit", "tens"):
                    if SCALES[w] == 100:
                        current *= 100
                    else:
                        total += current * SCALES[w]; current = 0
                    last = "scale"
                elif w == "and" and last == "scale" and j + 1 < len(tokens) and (tokens[j+1] in UNITS or tokens[j+1] in TENS):
                    pass
                else:
                    break
                j += 1
            out.append(str(total + current)); i = j
        else:
            out.append(t); i += 1
    return out

def normalize(text):
    t = text.lower()
    t = t.replace("’", "'")
    t = re.sub(r"\$\s?([\d,\.]+)", r"\1 dollars", t)
    t = t.replace("%", " percent")
    t = re.sub(r"(\d),(\d)", r"\1\2", t)
    t = re.sub(r"(\d+)(st|nd|rd|th)\b", r"\1", t)
    t = re.sub(r"(\d):(\d\d)", r"\1 \2", t)
    t = re.sub(r"[^a-z0-9' ]+", " ", t)
    t = t.replace("'", "")
    toks = [ORD.get(w, w) for w in t.split()]
    return words_to_digits(toks)

def align(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j] + 1, d[i][j-1] + 1, d[i-1][j-1] + (ref[i-1] != hyp[j-1]))
    i, j, ops = n, m, collections.Counter()
    while i > 0 or j > 0:
        if i > 0 and j > 0 and d[i][j] == d[i-1][j-1] + (ref[i-1] != hyp[j-1]):
            ops["S" if ref[i-1] != hyp[j-1] else "C"] += 1; i -= 1; j -= 1
        elif i > 0 and d[i][j] == d[i-1][j] + 1:
            ops["D"] += 1; i -= 1
        else:
            ops["I"] += 1; j -= 1
    return ops

def wilson(k, n, z=1.96):
    if n == 0: return (0, 0)
    p = k / n; den = 1 + z*z/n; c = (p + z*z/(2*n)) / den; h = z*math.sqrt(p*(1-p)/n + z*z/(4*n*n)) / den
    return (max(0, c - h), min(1, c + h))

def score(pairs):
    """Pooled counts. Words recognized on an empty reference (silence, noise)
    are insertions in the pooled rate and are also counted on their own in
    empty_refs and empty_ref_words. First and last words are checked only on
    the edge_utts references that have words."""
    tot = collections.Counter(); first = last = n = edges = empty = empty_words = 0
    for ref, hyp in pairs:
        r, h = normalize(ref), normalize(hyp)
        ops = align(r, h); tot += ops; tot["N"] += len(r); n += 1
        if not r:
            empty += 1; empty_words += len(h)
            continue
        edges += 1
        first += bool(h) and h[0] == r[0]; last += bool(h) and h[-1] == r[-1]
    errs = tot["S"] + tot["D"] + tot["I"]
    return dict(utts=n, words=tot["N"], S=tot["S"], D=tot["D"], I=tot["I"], wer=errs / max(tot["N"], 1),
                wer95=wilson(errs, tot["N"]), edge_utts=edges, first_ok=first, last_ok=last,
                empty_refs=empty, empty_ref_words=empty_words)
