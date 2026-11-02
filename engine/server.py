"""Earshot speech engine: a resident Kokoro (MLX) process driven over stdio.

Protocol (one JSON object per line on stdin):
  {"op": "synth", "id": 7, "text": "...", "voice": "af_heart", "speed": 1.0, "stretch": 2.0}
      speed = Kokoro's own pace; stretch = WSOLA time-compression on top. Measured with
      Whisper, natural pace + WSOLA is far clearer at 2-3x than asking Kokoro to rush.
  {"op": "transcribe", "id": 8, "audio": "<base64 int16 mono 16 kHz>", "model": "parakeet", "language": "en"}
  {"op": "warm_stt", "model": "parakeet"}   load a speech-to-text model ahead of time
  {"op": "cancel_before", "id": 7}   drop queued requests with a smaller id
  {"op": "voices"}
  {"op": "ping"}

Every reply on stdout is a JSON header line, optionally followed by exactly
`bytes` bytes of mono float32 little-endian PCM at `sr` Hz:
  {"type": "audio", "id": 7, "sr": 24000, "bytes": 123456, "words": [[0, 5, 0.11, 0.24], ...]}
      words = [UTF-16 offset, UTF-16 length, start s, end s] of each spoken word
  {"type": "error", "id": 7, "message": "..."}
  {"type": "voices", "voices": ["af_heart", ...]}
  {"type": "transcript", "id": 8, "text": "..."}
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


STT_MODELS = {
    # English: word-perfect on our tests and ~0.2 s for 14 s of speech on an M4.
    "parakeet": "mlx-community/parakeet-tdt-0.6b-v2",
    # Multilingual (Hindi, mixed Hindi-English): slower, used only when chosen.
    "whisper": "mlx-community/whisper-large-v3-turbo",
}
_stt = {}


def stt_model(name):
    if name not in _stt:
        if name == "whisper":
            import mlx_whisper  # loads lazily per call; keep a marker
            _stt[name] = mlx_whisper
        else:
            from mlx_audio.stt.utils import load_model as load_stt
            _stt[name] = load_stt(STT_MODELS["parakeet"])
            import mlx.core as mx
            _stt[name].generate(mx.array([0.0] * 16000, dtype=mx.float32))  # warm up kernels
    return _stt[name]


def transcribe(msg):
    import base64
    import numpy as np
    pcm = np.frombuffer(base64.b64decode(msg["audio"]), dtype="<i2").astype(np.float32) / 32768.0
    if pcm.size < 1600:
        return ""
    name = msg.get("model", "parakeet")
    model = stt_model(name)
    if name == "whisper":
        lang = msg.get("language") or None
        return model.transcribe(pcm, path_or_hf_repo=STT_MODELS["whisper"], language=lang)["text"].strip()
    import mlx.core as mx
    return model.generate(mx.array(pcm)).text.strip()


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
    # Warm both English pipelines so the first real request is fast.
    for voice in ("af_heart", "bf_emma"):
        for _ in model.generate("Ready.", voice=voice, speed=1.0, lang_code=lang_for(voice)):
            pass
    send({"type": "ready"})

    queue = deque()
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
                elif op in ("transcribe", "warm_stt"):
                    queue.appendleft(msg)  # someone is waiting on their words
                elif op == "cancel_before":
                    floor["id"] = max(floor["id"], int(msg["id"]))
                    for m in [m for m in queue if m.get("op") == "synth" and m["id"] < floor["id"]]:
                        queue.remove(m)
                elif op == "voices":
                    send({"type": "voices", "voices": list_voices(model_path)})
                elif op == "ping":
                    send({"type": "pong"})
                cond.notify()
        os._exit(0)  # stdin closed: the app quit

    threading.Thread(target=reader, daemon=True).start()

    while True:
        with cond:
            while not queue:
                cond.wait()
            msg = queue.popleft()
            if msg.get("op") == "warm_stt":
                try:
                    stt_model(msg.get("model", "parakeet"))
                except Exception:
                    traceback.print_exc()
                continue
            if msg.get("op") == "transcribe":
                try:
                    send({"type": "transcript", "id": msg["id"], "text": transcribe(msg)})
                except Exception as exc:
                    traceback.print_exc()
                    send({"type": "error", "id": msg["id"], "message": str(exc)})
                continue
            if msg["id"] < floor["id"]:
                continue
        try:
            voice = msg.get("voice") or "af_heart"
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
            audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
            audio = time_stretch(audio, stretch)
            data = audio.astype("<f4").tobytes()
            spans = align_words(msg["text"], words, stretch)
            send({"type": "audio", "id": msg["id"], "sr": SAMPLE_RATE, "bytes": len(data), "words": spans}, data)
        except Exception as exc:  # keep serving after a bad request
            traceback.print_exc()
            send({"type": "error", "id": msg["id"], "message": str(exc)})


if __name__ == "__main__":
    main()
