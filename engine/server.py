"""Earshot speech engine: a resident Kokoro (MLX) process driven over stdio.

Protocol (one JSON object per line on stdin):
  {"op": "synth", "id": 7, "text": "...", "voice": "af_heart", "speed": 1.0, "stretch": 2.0}
      speed = Kokoro's own pace; stretch = WSOLA time-compression on top. Measured with
      Whisper, natural pace + WSOLA is far clearer at 2-3x than asking Kokoro to rush.
  {"op": "cancel_before", "id": 7}   drop queued requests with a smaller id
  {"op": "voices"}
  {"op": "ping"}

Every reply on stdout is a JSON header line, optionally followed by exactly
`bytes` bytes of mono float32 little-endian PCM at `sr` Hz:
  {"type": "audio", "id": 7, "sr": 24000, "bytes": 123456}
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
                elif op == "cancel_before":
                    floor["id"] = max(floor["id"], int(msg["id"]))
                    for m in [m for m in queue if m["id"] < floor["id"]]:
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
            if msg["id"] < floor["id"]:
                continue
        try:
            voice = msg.get("voice") or "af_heart"
            chunks = [
                np.asarray(r.audio, dtype=np.float32)
                for r in model.generate(
                    msg["text"],
                    voice=voice,
                    speed=float(msg.get("speed", 1.0)),
                    lang_code=lang_for(voice),
                    split_pattern=r"\n+",
                )
            ]
            audio = np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
            audio = time_stretch(audio, float(msg.get("stretch", 1.0)))
            data = audio.astype("<f4").tobytes()
            send({"type": "audio", "id": msg["id"], "sr": SAMPLE_RATE, "bytes": len(data)}, data)
        except Exception as exc:  # keep serving after a bad request
            traceback.print_exc()
            send({"type": "error", "id": msg["id"], "message": str(exc)})


if __name__ == "__main__":
    main()
