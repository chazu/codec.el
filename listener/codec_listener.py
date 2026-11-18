#!/usr/bin/env python3
"""codec listener: microphone -> Silero VAD -> faster-whisper -> JSON lines.

The listener is the speech-to-text half of codec.el.  Emacs starts it
as a subprocess and talks to it over pipes.

Stdout carries one JSON object per line and nothing else:

    {"type": "ready", "device": "mps", "compute_type": "int8_float16"}
                                       model loaded, about to capture
    {"type": "listening"}              capturing, not muted
    {"type": "muted"}                  muted: audio is discarded
    {"type": "stopped"}                capture is off (push-to-talk seam)
    {"type": "utterance", "text": "."} one finished, filtered transcript
    {"type": "error", "message": "."}  something went wrong

Stdin takes one command per line: mute, unmute, start, stop, quit.
End of file on stdin means quit.  Logs go to stderr.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import platform
import queue
import re
import sys
import threading
from collections import deque
from dataclasses import dataclass
from typing import Callable, Iterable, Optional, TextIO

import numpy as np

log = logging.getLogger("codec")

SAMPLE_RATE = 16000
FRAME_SAMPLES = 512  # 32 ms, the window Silero VAD takes at 16 kHz
FRAME_MS = FRAME_SAMPLES * 1000 // SAMPLE_RATE

COMMANDS = frozenset({"mute", "unmute", "start", "stop", "quit"})

# Whisper's usual inventions on silence or breath noise.  Compared after
# `normalize', so case and punctuation do not matter.
DEFAULT_DROP_PHRASES = (
    "you",
    "thank you",
    "thanks",
    "thank you very much",
    "thanks for watching",
    "thank you for watching",
    "subtitles by the amara org community",
)

# Non-speech annotations such as "[BLANK_AUDIO]", "(music)" or "*cough*".
_ANNOTATION = re.compile(r"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*|♪")
_NON_WORD = re.compile(r"[^\w']+")


# ---------------------------------------------------------------------------
# Protocol


def encode(event_type: str, **fields: object) -> str:
    """Return the protocol line (without newline) for one event."""
    return json.dumps({"type": event_type, **fields}, separators=(",", ":"))


def parse_command(line: str) -> Optional[str]:
    """Return the command in LINE, or None if it is not a known command."""
    command = line.strip().lower()
    return command if command in COMMANDS else None


class Emitter:
    """Write protocol lines to a stream, one whole line at a time."""

    def __init__(self, stream: TextIO):
        self._stream = stream
        self._lock = threading.Lock()

    def __call__(self, event_type: str, **fields: object) -> None:
        line = encode(event_type, **fields)
        with self._lock:
            self._stream.write(line + "\n")
            self._stream.flush()


# ---------------------------------------------------------------------------
# Utterance filtering


def normalize(text: str) -> str:
    """Return TEXT lowercased, without punctuation, single-spaced."""
    return " ".join(_NON_WORD.sub(" ", text.lower()).split())


def clean_utterance(
    text: str, drop_phrases: Iterable[str] = DEFAULT_DROP_PHRASES, min_chars: int = 2
) -> Optional[str]:
    """Return TEXT tidied, or None if it is empty, too short or noise.

    Noise is a transcript that is only annotations such as "[BLANK_AUDIO]",
    or one that matches a phrase in DROP_PHRASES after `normalize'.
    """
    cleaned = " ".join(text.split())
    words = normalize(_ANNOTATION.sub(" ", cleaned))
    if len(words.replace(" ", "")) < min_chars:
        return None
    if words in {normalize(p) for p in drop_phrases}:
        return None
    return cleaned


# ---------------------------------------------------------------------------
# Segmentation


@dataclass
class SegmenterConfig:
    threshold: float = 0.5  # speech starts at or above this probability
    neg_threshold: float = 0.35  # silence is below this probability
    min_silence_ms: int = 900  # this much silence ends an utterance
    min_speech_ms: int = 250  # shorter utterances are dropped
    pre_roll_ms: int = 300  # audio kept from before speech started
    post_roll_ms: int = 200  # trailing silence kept after speech
    max_utterance_s: float = 30.0  # cut an utterance this long

    def frames(self, ms: float) -> int:
        return max(0, int(ms // FRAME_MS))


class Segmenter:
    """Cut a stream of frames into utterances from per-frame speech odds.

    Feed it each frame with the VAD's speech probability.  `feed' returns
    the audio of an utterance when trailing silence ends it.
    """

    def __init__(self, config: SegmenterConfig = SegmenterConfig()):
        self.config = config
        self.reset()

    def reset(self) -> None:
        """Forget any utterance in progress."""
        self._pre: deque = deque(maxlen=max(1, self.config.frames(self.config.pre_roll_ms)))
        self._frames: list = []
        self._in_speech = False
        self._speech_frames = 0
        self._silence_frames = 0

    @property
    def in_speech(self) -> bool:
        return self._in_speech

    def feed(self, frame: np.ndarray, prob: float) -> Optional[np.ndarray]:
        cfg = self.config
        if not self._in_speech:
            if prob >= cfg.threshold:
                self._in_speech = True
                self._frames = list(self._pre)
                self._pre.clear()
                self._frames.append(frame)
                self._speech_frames = 1
                self._silence_frames = 0
            else:
                self._pre.append(frame)
            return None

        self._frames.append(frame)
        if prob < cfg.neg_threshold:
            self._silence_frames += 1
        else:
            self._silence_frames = 0
            if prob >= cfg.threshold:
                self._speech_frames += 1

        if self._silence_frames >= max(1, cfg.frames(cfg.min_silence_ms)):
            return self._finish()
        if len(self._frames) * FRAME_MS >= cfg.max_utterance_s * 1000:
            return self._finish()
        return None

    def flush(self) -> Optional[np.ndarray]:
        """End the utterance in progress now, as if silence followed it."""
        if not self._in_speech:
            self.reset()
            return None
        return self._finish()

    def _finish(self) -> Optional[np.ndarray]:
        frames = self._frames
        excess = self._silence_frames - self.config.frames(self.config.post_roll_ms)
        if excess > 0:
            frames = frames[:-excess]
        long_enough = self._speech_frames * FRAME_MS >= self.config.min_speech_ms
        self.reset()
        if not long_enough or not frames:
            return None
        return np.concatenate(frames)


# ---------------------------------------------------------------------------
# Models (imported lazily so tests need neither onnxruntime nor a download)


class SileroVAD:
    """Streaming Silero VAD v6, the ONNX model bundled with faster-whisper."""

    CONTEXT = 64

    def __init__(self, path: Optional[str] = None):
        import onnxruntime

        if path is None:
            from faster_whisper.utils import get_assets_path

            path = os.path.join(get_assets_path(), "silero_vad_v6.onnx")
        opts = onnxruntime.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        opts.log_severity_level = 4
        self._session = onnxruntime.InferenceSession(
            path, providers=["CPUExecutionProvider"], sess_options=opts
        )
        self.reset()

    def reset(self) -> None:
        self._h = np.zeros((1, 1, 128), dtype=np.float32)
        self._c = np.zeros((1, 1, 128), dtype=np.float32)
        self._context = np.zeros(self.CONTEXT, dtype=np.float32)

    def __call__(self, frame: np.ndarray) -> float:
        x = np.concatenate([self._context, frame]).astype(np.float32)[None, :]
        out, self._h, self._c = self._session.run(
            None, {"input": x, "h": self._h, "c": self._c}
        )
        self._context = frame[-self.CONTEXT :]
        return float(out[0])


# The compute type that "auto" means on each device.  On MPS, CTranslate2
# runs int8_float16 as float16; on the CPU, int8 is the fastest.
AUTO_COMPUTE_TYPES = {"mps": "int8_float16", "cpu": "int8", "auto": "int8"}
FALLBACK = ("cpu", "int8")


def resolve_device(
    device: str,
    compute_type: str,
    system: Optional[str] = None,
    machine: Optional[str] = None,
) -> tuple:
    """Return the (device, compute type) to try first.

    Device "auto" means "mps" on Apple Silicon and CTranslate2's own
    choice elsewhere, because CTranslate2's "auto" never picks MPS.
    Compute type "auto" means the entry for the device in
    AUTO_COMPUTE_TYPES, else CTranslate2's "default".  Other values are
    used as given.
    """
    system = platform.system() if system is None else system
    machine = platform.machine() if machine is None else machine
    if device == "auto" and system == "Darwin" and machine == "arm64":
        device = "mps"
    if compute_type == "auto":
        compute_type = AUTO_COMPUTE_TYPES.get(device, "default")
    return device, compute_type


def load_transcriber(
    loader: Callable[..., Callable[[np.ndarray], str]],
    device: str,
    compute_type: str,
    **kwargs: object,
) -> tuple:
    """Return (transcriber, device, compute type) from LOADER.

    LOADER takes DEVICE, COMPUTE_TYPE and KWARGS as keywords.  If it
    fails on MPS, log why and load on the CPU instead.  The device
    returned is the one the model reports, if it reports one, so that
    "auto" becomes "cpu" or "cuda".
    """
    try:
        transcriber = loader(device=device, compute_type=compute_type, **kwargs)
    except Exception as e:
        if device != "mps":
            raise
        log.warning("cannot load the model on mps (%s); using %s/%s", e, *FALLBACK)
        device, compute_type = FALLBACK
        transcriber = loader(device=device, compute_type=compute_type, **kwargs)
    return transcriber, getattr(transcriber, "device", None) or device, compute_type


class WhisperTranscriber:
    """Transcribe one utterance with faster-whisper."""

    def __init__(
        self,
        model: str,
        device: str = "auto",
        compute_type: str = "int8",
        language: Optional[str] = "en",
        beam_size: int = 5,
        download_root: Optional[str] = None,
    ):
        from faster_whisper import WhisperModel

        # CTranslate2 logs, such as its tip to try MPS, go to stderr.
        self._model = WhisperModel(
            model, device=device, compute_type=compute_type, download_root=download_root
        )
        self._language = language
        self._beam_size = beam_size

    @property
    def device(self) -> Optional[str]:
        """The device the model runs on, such as "mps" or "cpu"."""
        return getattr(self._model.model, "device", None)

    def __call__(self, audio: np.ndarray) -> str:
        segments, _info = self._model.transcribe(
            audio,
            language=self._language,
            beam_size=self._beam_size,
            vad_filter=False,
            condition_on_previous_text=False,
            without_timestamps=True,
        )
        return " ".join(s.text.strip() for s in segments).strip()


# ---------------------------------------------------------------------------
# The listener


class Listener:
    """Turn audio and commands into protocol events.

    Audio and commands go through one queue and `dispatch' handles them
    in order on one thread, so segmentation state needs no locks.
    Finished utterances go to a second queue for `transcribe_next'.
    """

    def __init__(
        self,
        vad: Callable[[np.ndarray], float],
        segmenter: Segmenter,
        transcriber: Callable[[np.ndarray], str],
        emit: Callable[..., None],
        drop_phrases: Iterable[str] = DEFAULT_DROP_PHRASES,
        min_chars: int = 2,
        capturing: bool = True,
        muted: bool = False,
    ):
        self.vad = vad
        self.segmenter = segmenter
        self.transcriber = transcriber
        self.emit = emit
        self.drop_phrases = tuple(drop_phrases)
        self.min_chars = min_chars
        self.capturing = capturing
        self.muted = muted
        self.inbox: queue.Queue = queue.Queue()
        self.utterances: queue.Queue = queue.Queue()
        self._pending = np.zeros(0, dtype=np.float32)

    @property
    def active(self) -> bool:
        return self.capturing and not self.muted

    def state(self) -> str:
        if self.muted:
            return "muted"
        return "listening" if self.capturing else "stopped"

    def emit_state(self) -> None:
        self.emit(self.state())

    # Producers (any thread)

    def put_audio(self, samples: np.ndarray) -> None:
        if self.active:
            self.inbox.put(("audio", samples))

    def put_command(self, command: str) -> None:
        self.inbox.put(("command", command))

    # Consumer (one thread)

    def dispatch(self, item: tuple) -> bool:
        """Handle one inbox item.  Return False when it is time to quit."""
        kind, value = item
        if kind == "audio":
            if self.active:
                self.process_audio(value)
            return True
        return self.handle_command(value)

    def handle_command(self, command: str) -> bool:
        if command == "quit":
            return False
        if command == "mute":
            self.muted = True
            self._discard()
        elif command == "unmute":
            self.muted = False
        elif command == "start":
            self.capturing = True
        elif command == "stop":
            self.capturing = False
            self._queue(self.segmenter.flush())
            self._discard()
        else:
            self.emit("error", message=f"unknown command: {command}")
            return True
        self.emit_state()
        return True

    def process_audio(self, samples: np.ndarray) -> None:
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        buf = np.concatenate([self._pending, samples])
        whole = len(buf) - len(buf) % FRAME_SAMPLES
        for start in range(0, whole, FRAME_SAMPLES):
            frame = buf[start : start + FRAME_SAMPLES]
            self._queue(self.segmenter.feed(frame, self.vad(frame)))
        self._pending = buf[whole:]

    def _queue(self, audio: Optional[np.ndarray]) -> None:
        if audio is not None:
            self.utterances.put(audio)

    def _discard(self) -> None:
        self.segmenter.reset()
        self._pending = np.zeros(0, dtype=np.float32)
        reset = getattr(self.vad, "reset", None)
        if reset:
            reset()

    # Transcription (its own thread, so VAD keeps up while Whisper runs)

    def transcribe(self, audio: np.ndarray) -> Optional[str]:
        """Transcribe AUDIO and emit it unless it is noise or we are muted."""
        try:
            text = clean_utterance(self.transcriber(audio), self.drop_phrases, self.min_chars)
        except Exception as e:  # keep listening after a bad utterance
            log.exception("transcription failed")
            self.emit("error", message=f"transcription failed: {e}")
            return None
        if text is None:
            log.info("dropped noise transcript")
            return None
        if self.muted:
            log.info("dropped transcript that finished while muted")
            return None
        self.emit("utterance", text=text)
        return text

    def transcribe_next(self, timeout: Optional[float] = None) -> Optional[str]:
        return self.transcribe(self.utterances.get(timeout=timeout))


# ---------------------------------------------------------------------------
# Command line


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--model", default="small.en", help="Whisper model name or path")
    p.add_argument(
        "--device", default="auto", help="mps, cpu, cuda or auto (mps on Apple Silicon)"
    )
    p.add_argument(
        "--compute-type",
        default="auto",
        help="CTranslate2 compute type, or auto (int8_float16 on mps, int8 on cpu)",
    )
    p.add_argument("--language", default="en", help="language code, or '' to detect")
    p.add_argument("--beam-size", type=int, default=5)
    p.add_argument("--download-root", default=None, help="model cache directory")
    p.add_argument("--input-device", default=None, help="sounddevice input device")
    p.add_argument("--threshold", type=float, default=0.5, help="VAD speech probability")
    p.add_argument("--silence-ms", type=int, default=900, help="silence that ends an utterance")
    p.add_argument("--min-speech-ms", type=int, default=250)
    p.add_argument("--max-utterance-s", type=float, default=30.0)
    p.add_argument("--min-chars", type=int, default=2, help="shorter transcripts are dropped")
    p.add_argument(
        "--drop-phrase", action="append", default=[], help="transcript to drop (repeatable)"
    )
    p.add_argument(
        "--no-default-drop-phrases",
        action="store_true",
        help="drop only the --drop-phrase phrases",
    )
    p.add_argument("--no-autostart", action="store_true", help="wait for 'start' to capture")
    p.add_argument("--muted", action="store_true", help="start muted")
    p.add_argument("--download-only", action="store_true", help="fetch the model and exit")
    p.add_argument("--log-level", default="INFO")
    return p


def _read_commands(listener: Listener, ready: threading.Event, stdin: TextIO) -> None:
    for line in stdin:
        if not line.strip():
            continue
        command = parse_command(line)
        if command is None:
            listener.emit("error", message=f"unknown command: {line.strip()}")
            continue
        if command == "quit" and not ready.is_set():
            os._exit(0)  # still loading the model; nothing to clean up
        listener.put_command(command)
    if not ready.is_set():
        os._exit(0)
    listener.put_command("quit")


def _transcribe_forever(listener: Listener) -> None:
    while True:
        listener.transcribe_next()


def main(
    argv: Optional[list] = None,
    loader: Callable[..., Callable[[np.ndarray], str]] = WhisperTranscriber,
    make_vad: Callable[[], Callable[[np.ndarray], float]] = SileroVAD,
) -> int:
    """Run the listener.  LOADER and MAKE_VAD load the models."""
    args = build_parser().parse_args(argv)
    logging.basicConfig(
        stream=sys.stderr,
        level=args.log_level.upper(),
        format="%(asctime)s %(levelname)s %(message)s",
    )
    # Only protocol lines may reach stdout; send stray prints to stderr.
    emit = Emitter(sys.stdout)
    sys.stdout = sys.stderr

    drop = tuple(args.drop_phrase)
    if not args.no_default_drop_phrases:
        drop = DEFAULT_DROP_PHRASES + drop
    config = SegmenterConfig(
        threshold=args.threshold,
        neg_threshold=max(0.0, args.threshold - 0.15),
        min_silence_ms=args.silence_ms,
        min_speech_ms=args.min_speech_ms,
        max_utterance_s=args.max_utterance_s,
    )
    listener = Listener(
        vad=lambda frame: 0.0,  # replaced once loaded
        segmenter=Segmenter(config),
        transcriber=lambda audio: "",
        emit=emit,
        drop_phrases=drop,
        min_chars=args.min_chars,
        capturing=not args.no_autostart,
        muted=args.muted,
    )
    ready = threading.Event()
    if not args.download_only:
        threading.Thread(
            target=_read_commands, args=(listener, ready, sys.stdin), daemon=True
        ).start()

    device, compute_type = resolve_device(args.device, args.compute_type)
    try:
        log.info("loading Whisper model %s on %s/%s", args.model, device, compute_type)
        listener.transcriber, device, compute_type = load_transcriber(
            loader,
            device,
            compute_type,
            model=args.model,
            language=args.language or None,
            beam_size=args.beam_size,
            download_root=args.download_root,
        )
        log.info("model loaded on %s/%s", device, compute_type)
        listener.vad = make_vad()
    except Exception as e:
        log.exception("model load failed")
        emit("error", message=f"model load failed: {e}")
        return 1
    if args.download_only:
        emit("ready", device=device, compute_type=compute_type)
        return 0

    def on_audio(data, _frames, _time, status):
        if status:
            log.warning("audio: %s", status)
        listener.put_audio(data[:, 0].copy())

    try:
        import sounddevice as sd

        stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            dtype="float32",
            blocksize=FRAME_SAMPLES,
            device=args.input_device,
            callback=on_audio,
        )
        stream.start()
    except Exception as e:
        log.exception("microphone failed")
        emit("error", message=f"microphone failed: {e}")
        return 1

    ready.set()
    emit("ready", device=device, compute_type=compute_type)
    listener.emit_state()
    threading.Thread(target=_transcribe_forever, args=(listener,), daemon=True).start()
    try:
        while listener.dispatch(listener.inbox.get()):
            pass
    except KeyboardInterrupt:
        pass
    finally:
        stream.stop()
        stream.close()
    log.info("bye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
