"""Earshot speech engine: a resident Kokoro (MLX) process driven over stdio.

Protocol (one JSON object per line on stdin):
  {"op": "synth", "id": 7, "text": "...", "voice": "af_heart", "speed": 1.0, "stretch": 2.0, "also": [3.0, 1.5]}
      also = extra speeds made from the same voice pass (for instant speed switches)
      speed = Kokoro's own pace; stretch = WSOLA time-compression on top. Measured with
      Whisper, natural pace + WSOLA is far clearer at 2-3x than asking Kokoro to rush.
  {"op": "cancel_before", "id": 7}   drop queued requests with a smaller id
  {"op": "warm", "voice": "af_heart"}   a reading is about to start: page the voice in now
  {"op": "voices"}
  {"op": "ping"}

Every reply on stdout is a JSON header line, optionally followed by exactly
`bytes` bytes of mono float32 little-endian PCM at `sr` Hz:
  {"type": "audio", "id": 7, "sr": 24000, "bytes": 123456, "words": [[0, 5, 0.11, 0.24], ...]}
      words = [UTF-16 offset, UTF-16 length, start s, end s] of each spoken word
      parts = one entry per speed, {"stretch", "bytes", "words"}; the body is their audio in order
  {"type": "error", "id": 7, "message": "..."}
  {"type": "voices", "voices": ["af_heart", ...]}
  {"type": "ready"} / {"type": "pong"}

Libraries print to stdout, so the protocol uses a private dup of fd 1 and
everything else (print, warnings, logging) goes to stderr.
"""

import json
import os
import sys
import threading
import traceback
from collections import deque

PROTO = os.fdopen(os.dup(1), "wb", buffering=0)
os.dup2(2, 1)
sys.stdout = sys.stderr

MODEL_ID = os.environ.get("EARSHOT_MODEL", "prince-canuma/Kokoro-82M")
SAMPLE_RATE = 24000
write_lock = threading.Lock()


def send(header, payload=b""):
    with write_lock:
        PROTO.write(json.dumps(header).encode() + b"\n")
        if payload:
            PROTO.write(payload)


def time_stretch(audio, rate):
    """WSOLA time-scale modification: faster speech, same pitch, no phasiness."""
    if abs(rate - 1.0) < 0.01 or audio.size == 0:
        return audio
    from audiotsm import wsola
    from audiotsm.io.array import ArrayReader, ArrayWriter
    writer = ArrayWriter(1)
    wsola(1, speed=rate, frame_length=512, synthesis_hop=128).run(ArrayReader(audio.reshape(1, -1)), writer)
    return writer.data[0].astype("float32")


def word_times(tokens, offset):
    """(text, start s, end s) per spoken word of one Kokoro segment."""
    out = []
    for t in tokens or []:
        if t.start_ts is None or t.end_ts is None or not any(ch.isalnum() for ch in t.text):
            continue
        out.append((t.text, offset + t.start_ts, offset + t.end_ts))
    return out


def align_words(text, words, stretch):
    """[[utf16 start, utf16 length, start s, end s], ...] in the input text, with
    times scaled for the time-stretch. Words not found nearby are left out."""
    spans, cursor = [], 0
    for w, t0, t1 in words:
        i = text.find(w, cursor, cursor + 80 + len(w))
        if i < 0:
            continue
        start16 = len(text[:i].encode("utf-16-le")) // 2
        len16 = len(w.encode("utf-16-le")) // 2
        spans.append([start16, len16, round(t0 / stretch, 3), round(t1 / stretch, 3)])
        cursor = i + len(w)
    return spans


def lang_for(voice):
    # Kokoro voice ids start with a language letter: a = US English, b = UK English, ...
    return voice[0] if voice else "a"


def list_voices(model_path):
    folder = os.path.join(model_path, "voices")
    if not os.path.isdir(folder):
        return []
    names = [f.rsplit(".", 1)[0] for f in os.listdir(folder) if f.endswith((".safetensors", ".pt", ".npy"))]
    # Only English pipelines are installed (misaki[en]).
    return sorted(n for n in set(names) if n[:1] in ("a", "b"))


def main():
    import numpy as np
    from huggingface_hub import snapshot_download
    from mlx_audio.tts.utils import load_model

    model = load_model(MODEL_ID)
    model_path = snapshot_download(MODEL_ID)
    # Keep the voice in RAM: when the Mac is short of memory, macOS otherwise
    # moves the model to disk and each sentence waits seconds to read it back.
    import mlx.core as mx
    try:
        mx.set_wired_limit(int(1.5 * 1024 ** 3))
        # MLX keeps freed GPU buffers for reuse, up to ~12 GB by default. Every
        # sentence has a different size, so that cache only grows — it took most
        # of the Mac's memory. Keep it small; it's emptied after each sentence too.
        mx.set_cache_limit(256 * 1024 ** 2)
    except Exception:
        traceback.print_exc()
    # Warm both English pipelines so the first real request is fast.
    for voice in ("af_heart", "bf_emma"):
        for _ in model.generate("Ready.", voice=voice, speed=1.0, lang_code=lang_for(voice)):
            pass
    send({"type": "ready"})

    queue = deque()
    last_voice = {"v": "af_heart"}
    cond = threading.Condition()
    floor = {"id": -1}

    def reader():
        for line in sys.stdin:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            op = msg.get("op")
            with cond:
                if op == "synth":
                    queue.append(msg)
                elif op == "cancel_before":
                    floor["id"] = max(floor["id"], int(msg["id"]))
                    for m in [m for m in queue if m.get("op") == "synth" and m["id"] < floor["id"]]:
                        queue.remove(m)
                elif op == "voices":
                    send({"type": "voices", "voices": list_voices(model_path)})
                elif op == "warm":
                    queue.appendleft(msg)  # a reading is about to start
                elif op == "ping":
                    send({"type": "pong"})
                cond.notify()
        os._exit(0)  # stdin closed: the app quit

    threading.Thread(target=reader, daemon=True).start()

    while True:
        with cond:
            idle = False
            while not queue:
                # Idle for 25 s: make a tiny sentence so nothing of the engine
                # (model, pronunciation rules) gets pushed out to disk.
                if not cond.wait(timeout=25):
                    idle = True
                    break
            msg = {"op": "warm"} if idle else queue.popleft()
        if msg.get("op") == "warm":
            try:
                voice = msg.get("voice") or last_voice["v"]
                for _ in model._get_pipeline(lang_for(voice))("Ready.", voice=voice, speed=1.0):
                    pass
                mx.clear_cache()
            except Exception:
                traceback.print_exc()
            continue
        with cond:
            if msg["id"] < floor["id"]:
                continue
        try:
            voice = msg.get("voice") or "af_heart"
            last_voice["v"] = voice
            stretch = float(msg.get("stretch", 1.0))
            pipeline = model._get_pipeline(lang_for(voice))
            chunks, words, offset = [], [], 0.0
            for r in pipeline(msg["text"], voice=voice, speed=float(msg.get("speed", 1.0)), split_pattern=r"\n+"):
                if r.audio is None:
                    continue
                a = np.asarray(r.audio, dtype=np.float32).reshape(-1)
                words.extend(word_times(r.tokens, offset))
                chunks.append(a)
                offset += a.size / SAMPLE_RATE
            natural = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
            # The voice is generated once at its natural pace; each speed is only
            # a time-compression of it, so extra speeds cost little.
            parts, blobs = [], []
            for st in [stretch] + [float(x) for x in msg.get("also", []) if abs(float(x) - stretch) > 0.01]:
                data = time_stretch(natural, st).astype("<f4").tobytes()
                parts.append({"stretch": st, "bytes": len(data), "words": align_words(msg["text"], words, st)})
                blobs.append(data)
            body = b"".join(blobs)
            send({"type": "audio", "id": msg["id"], "sr": SAMPLE_RATE, "bytes": len(body),
                  "words": parts[0]["words"], "parts": parts}, body)
            mx.clear_cache()
        except Exception as exc:  # keep serving after a bad request
            traceback.print_exc()
            send({"type": "error", "id": msg["id"], "message": str(exc)})


if __name__ == "__main__":
    main()
