"""Builds long real-speech dictations from LibriSpeech test-clean (CC BY 4.0,
https://www.openslr.org/12): consecutive utterances of one speaker's chapter,
decoded to 16 kHz mono 16-bit WAV.

  gapped:     the first chapter, utterances as published, 0.4 s of silence
              between them, about 30, 60 or 120 s per speaker
  continuous: the last chapter, each utterance trimmed to 50 ms around its
              speech and butted against the next, about 60 s per speaker

Usage: python3 -I make-librispeech-long.py <LibriSpeech/test-clean> <output-folder> gapped|continuous
Writes the WAV files and refs.json (the official transcripts, joined).
"""
import json, os, struct, subprocess, sys, wave

root, out, mode = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)


def pcm(path, trim):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path, "-f", "s16le", "-ar", "16000", "-ac", "1", "-"],
                         check=True, capture_output=True).stdout
    if not trim:
        return raw
    s = struct.unpack("<%dh" % (len(raw) // 2), raw)
    first = next((i for i, x in enumerate(s) if abs(x) > 400), 0)
    last = len(s) - next((i for i, x in enumerate(reversed(s)) if abs(x) > 400), 0)
    first, last = max(0, first - 800), min(len(s), last + 800)
    return raw[2 * first:2 * last]


refs = {}
gap = b"\x00\x00" * int(0.4 * 16000) if mode == "gapped" else b""
for index, speaker in enumerate(sorted(os.listdir(root))):
    chapters = sorted(os.listdir(os.path.join(root, speaker)))
    chapter = chapters[0] if mode == "gapped" else chapters[-1]
    folder = os.path.join(root, speaker, chapter)
    transcripts = dict(line.strip().split(" ", 1) for line in open(os.path.join(folder, f"{speaker}-{chapter}.trans.txt")))
    target, ceiling = ([30, 60, 120][index % 3], 10) if mode == "gapped" else (60, 10)
    chunks, texts, total = [], [], 0.0
    for key in sorted(transcripts):
        audio = pcm(os.path.join(folder, key + ".flac"), trim=mode == "continuous")
        seconds = len(audio) / 32000
        if chunks and total + seconds > target + ceiling:
            break
        chunks.append(audio); texts.append(transcripts[key]); total += seconds
        if total >= target:
            break
    name = f"libri-{target:03d}s-{speaker}" if mode == "gapped" else f"cont-{speaker}"
    with wave.open(os.path.join(out, name + ".wav"), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(gap.join(chunks))
    refs[name] = " ".join(texts)
json.dump(refs, open(os.path.join(out, "refs.json"), "w"), indent=1)
print(len(refs), "files")
