"""Tests for codec_listener that need no microphone and no model."""

import io
import json
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import codec_listener as cl  # noqa: E402

FRAME = cl.FRAME_SAMPLES


def frames(n, value=0.0):
    return [np.full(FRAME, value, dtype=np.float32) for _ in range(n)]


def ms(n_frames):
    return n_frames * cl.FRAME_MS


# --- Protocol --------------------------------------------------------------


def test_encode_is_one_json_line():
    line = cl.encode("utterance", text='say "hi"\nthere')
    assert "\n" not in line
    assert json.loads(line) == {"type": "utterance", "text": 'say "hi"\nthere'}


def test_encode_escapes_non_ascii():
    line = cl.encode("utterance", text="café ♪")
    assert line.isascii()
    assert json.loads(line)["text"] == "café ♪"


def test_emitter_writes_whole_lines_and_flushes():
    out = io.StringIO()
    emit = cl.Emitter(out)
    emit("ready")
    emit("error", message="boom")
    lines = out.getvalue().splitlines()
    assert [json.loads(l) for l in lines] == [
        {"type": "ready"},
        {"type": "error", "message": "boom"},
    ]


@pytest.mark.parametrize(
    "line,expected",
    [
        ("mute\n", "mute"),
        ("  UNMUTE \r\n", "unmute"),
        ("start", "start"),
        ("stop", "stop"),
        ("quit\n", "quit"),
        ("", None),
        ("mute now", None),
        ("shutdown", None),
    ],
)
def test_parse_command(line, expected):
    assert cl.parse_command(line) == expected


# --- Filtering -------------------------------------------------------------


@pytest.mark.parametrize(
    "text",
    ["", "   ", ".", "a", "you", " You. ", "Thank you.", "THANK YOU!", "[BLANK_AUDIO]", "(music)", "♪ ♪"],
)
def test_noise_is_dropped(text):
    assert cl.clean_utterance(text) is None


def test_real_speech_is_kept_and_tidied():
    assert cl.clean_utterance("  Run the   tests again. ") == "Run the tests again."


def test_phrase_inside_a_sentence_is_kept():
    assert cl.clean_utterance("Thank you, now commit it.") == "Thank you, now commit it."


def test_custom_drop_phrases():
    assert cl.clean_utterance("Okay.", drop_phrases=["okay"]) is None
    assert cl.clean_utterance("you", drop_phrases=["okay"]) == "you"


@pytest.mark.parametrize(
    "text",
    ["Um...", "um", "UM.", "Uh, um", "uh... um... hmm?", "Hmm.", "Mhm!", "Oh.", "Erm, er, ah, eh"],
)
def test_filler_only_is_dropped(text):
    assert cl.clean_utterance(text) is None


@pytest.mark.parametrize(
    "text", ["Um, run the tests.", "Uh... yes", "But, yeah.", "Yeah.", "No.", "Oh, commit it."]
)
def test_filler_with_other_words_is_kept(text):
    assert cl.clean_utterance(text) == text


def test_custom_filler_words():
    assert cl.clean_utterance("Like, like.", filler_words=["like"]) is None
    assert cl.clean_utterance("Um.", filler_words=["like"]) == "Um."


def test_no_filler_words_keeps_filler():
    assert cl.clean_utterance("Um...", drop_phrases=[], filler_words=[]) == "Um..."


def test_min_chars():
    assert cl.clean_utterance("ok", drop_phrases=[], min_chars=3) is None
    assert cl.clean_utterance("yes", drop_phrases=[], min_chars=3) == "yes"


# --- Segmentation ----------------------------------------------------------


def run(segmenter, probs):
    """Feed frames whose sample value is their index; return utterances."""
    out = []
    for i, p in enumerate(probs):
        audio = segmenter.feed(np.full(FRAME, float(i), dtype=np.float32), p)
        if audio is not None:
            out.append(audio)
    return out


def frame_ids(audio):
    return [int(v) for v in audio[::FRAME]]


def test_silence_alone_yields_nothing():
    assert run(cl.Segmenter(), [0.0] * 200) == []


def test_speech_then_silence_yields_one_utterance():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(10), pre_roll_ms=ms(3), post_roll_ms=ms(2), min_speech_ms=ms(5))
    probs = [0.0] * 20 + [0.9] * 30 + [0.0] * 15
    (audio,) = run(cl.Segmenter(cfg), probs)
    ids = frame_ids(audio)
    # 3 frames of pre-roll, all 30 speech frames, 2 frames of post-roll.
    assert ids == list(range(17, 52))


def test_utterance_ends_only_after_enough_silence():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(10), min_speech_ms=ms(1))
    seg = cl.Segmenter(cfg)
    assert run(seg, [0.9] * 5 + [0.0] * 9) == []
    assert seg.in_speech
    assert seg.feed(np.zeros(FRAME, dtype=np.float32), 0.0) is not None
    assert not seg.in_speech


def test_short_pause_does_not_split():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(10), min_speech_ms=ms(1))
    probs = [0.9] * 10 + [0.0] * 5 + [0.9] * 10 + [0.0] * 10
    assert len(run(cl.Segmenter(cfg), probs)) == 1


def test_middling_probability_keeps_speech_going():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(5), min_speech_ms=ms(1))
    probs = [0.9] * 5 + [0.4] * 20 + [0.0] * 5
    (audio,) = run(cl.Segmenter(cfg), probs)
    assert len(audio) >= 25 * FRAME


def test_two_utterances():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(5), min_speech_ms=ms(1))
    probs = ([0.9] * 10 + [0.0] * 10) * 2
    assert len(run(cl.Segmenter(cfg), probs)) == 2


def test_blip_shorter_than_min_speech_is_dropped():
    cfg = cl.SegmenterConfig(min_silence_ms=ms(5), min_speech_ms=ms(8))
    assert run(cl.Segmenter(cfg), [0.9] * 3 + [0.0] * 10) == []


def test_long_utterance_is_cut():
    cfg = cl.SegmenterConfig(min_speech_ms=ms(1), max_utterance_s=ms(20) / 1000)
    assert len(run(cl.Segmenter(cfg), [0.9] * 45)) == 2


def test_flush_ends_utterance_in_progress():
    cfg = cl.SegmenterConfig(min_speech_ms=ms(1))
    seg = cl.Segmenter(cfg)
    run(seg, [0.9] * 10)
    assert seg.flush() is not None
    assert seg.flush() is None


# --- Listener --------------------------------------------------------------


class FakeVAD:
    """Speech probability is the frame's first sample; counts resets."""

    def __init__(self):
        self.resets = 0

    def __call__(self, frame):
        return float(frame[0])

    def reset(self):
        self.resets += 1


class Recorder:
    def __init__(self):
        self.events = []

    def __call__(self, event_type, **fields):
        self.events.append({"type": event_type, **fields})

    def types(self):
        return [e["type"] for e in self.events]


def make_listener(text="Run the tests.", **kw):
    events = Recorder()
    cfg = cl.SegmenterConfig(min_silence_ms=ms(5), min_speech_ms=ms(2))
    listener = cl.Listener(
        vad=FakeVAD(),
        segmenter=cl.Segmenter(cfg),
        transcriber=lambda audio: text,
        emit=events,
        **kw,
    )
    return listener, events


def speak(listener, speech=10, silence=10):
    """Feed speech then silence in odd-sized chunks, as a sound card would."""
    audio = np.concatenate(frames(speech, 0.9) + frames(silence, 0.0))
    for chunk in np.array_split(audio, 7):
        listener.dispatch(("audio", chunk))


def test_utterance_is_transcribed_and_emitted():
    listener, events = make_listener()
    speak(listener)
    assert listener.transcribe_next(timeout=1) == "Run the tests."
    assert events.events == [{"type": "utterance", "text": "Run the tests."}]


def test_noise_transcript_is_not_emitted():
    listener, events = make_listener(text=" you ")
    speak(listener)
    assert listener.transcribe_next(timeout=1) is None
    assert events.events == []


def test_filler_transcript_is_not_emitted():
    listener, events = make_listener(text="Um...")
    speak(listener)
    assert listener.transcribe_next(timeout=1) is None
    assert events.events == []


def test_transcriber_failure_reports_error_and_carries_on():
    def boom(audio):
        raise RuntimeError("bad audio")

    listener, events = make_listener()
    listener.transcriber = boom
    speak(listener)
    assert listener.transcribe_next(timeout=1) is None
    assert events.types() == ["error"]
    assert "bad audio" in events.events[0]["message"]


def test_mute_discards_audio_and_unmute_resumes():
    listener, events = make_listener()
    listener.dispatch(("audio", np.concatenate(frames(5, 0.9))))
    assert listener.handle_command("mute")
    assert listener.vad.resets == 1
    assert not listener.segmenter.in_speech
    speak(listener)
    assert listener.utterances.empty()
    listener.put_audio(np.zeros(FRAME, dtype=np.float32))
    assert listener.inbox.empty()
    assert listener.handle_command("unmute")
    speak(listener)
    assert not listener.utterances.empty()
    assert events.types() == ["muted", "listening"]


def test_utterance_finishing_while_muted_is_dropped():
    listener, events = make_listener()
    speak(listener)
    listener.handle_command("mute")
    assert listener.transcribe_next(timeout=1) is None
    assert events.types() == ["muted"]


def test_stop_flushes_and_start_resumes():
    listener, events = make_listener()
    listener.dispatch(("audio", np.concatenate(frames(10, 0.9))))
    listener.handle_command("stop")
    assert not listener.utterances.empty()  # push-to-talk release
    assert not listener.active
    listener.handle_command("start")
    assert listener.active
    assert events.types() == ["stopped", "listening"]


def test_no_autostart_waits_for_start():
    listener, events = make_listener(capturing=False)
    assert listener.state() == "stopped"
    speak(listener)
    assert listener.utterances.empty()


def test_muted_state_wins_over_capture():
    listener, events = make_listener(muted=True)
    listener.handle_command("start")
    assert events.types() == ["muted"]


def test_quit_and_unknown_commands():
    listener, events = make_listener()
    assert listener.dispatch(("command", "quit")) is False
    assert listener.dispatch(("command", "dance")) is True
    assert events.types() == ["error"]


def test_read_commands_queues_commands_and_quits_on_eof():
    import threading

    listener, events = make_listener()
    ready = threading.Event()
    ready.set()
    cl._read_commands(listener, ready, io.StringIO("mute\n\nbogus\nunmute\n"))
    items = []
    while not listener.inbox.empty():
        items.append(listener.inbox.get())
    assert items == [("command", "mute"), ("command", "unmute"), ("command", "quit")]
    assert events.types() == ["error"]


def test_parser_defaults():
    args = cl.build_parser().parse_args([])
    assert args.model == "small.en"
    assert args.silence_ms == 900
    assert args.device == "auto"
    assert args.compute_type == "auto"
    args = cl.build_parser().parse_args(["--drop-phrase", "okay", "--drop-phrase", "bye"])
    assert args.drop_phrase == ["okay", "bye"]
    assert args.filler_word == []
    args = cl.build_parser().parse_args(["--filler-word", "like", "--filler-word", "so"])
    assert args.filler_word == ["like", "so"]


# --- Device ----------------------------------------------------------------


@pytest.mark.parametrize(
    "device, compute_type, system, machine, expected",
    [
        ("auto", "auto", "Darwin", "arm64", ("mps", "int8_float16")),
        ("auto", "auto", "Darwin", "x86_64", ("auto", "int8")),
        ("auto", "auto", "Linux", "x86_64", ("auto", "int8")),
        ("auto", "auto", "Linux", "aarch64", ("auto", "int8")),
        ("cpu", "auto", "Darwin", "arm64", ("cpu", "int8")),
        ("cuda", "auto", "Linux", "x86_64", ("cuda", "default")),
        ("mps", "float16", "Darwin", "arm64", ("mps", "float16")),
        ("auto", "float32", "Darwin", "arm64", ("mps", "float32")),
        ("cpu", "int8_float32", "Linux", "x86_64", ("cpu", "int8_float32")),
    ],
)
def test_resolve_device(device, compute_type, system, machine, expected):
    assert cl.resolve_device(device, compute_type, system, machine) == expected


class FakeLoader:
    """Record each load; fail on the devices in FAIL_ON."""

    def __init__(self, fail_on=(), reported=None):
        self.calls = []
        self.fail_on = fail_on
        self.reported = reported

    def __call__(self, device, compute_type, **kwargs):
        self.calls.append((device, compute_type, kwargs))
        if device in self.fail_on:
            raise RuntimeError(f"no {device} here")
        transcriber = lambda audio: "text"  # noqa: E731
        transcriber.device = self.reported or device
        return transcriber


def test_load_transcriber_uses_mps_when_it_loads():
    loader = FakeLoader()
    _t, device, compute_type = cl.load_transcriber(
        loader, "mps", "int8_float16", model="tiny.en"
    )
    assert (device, compute_type) == ("mps", "int8_float16")
    assert loader.calls == [("mps", "int8_float16", {"model": "tiny.en"})]


def test_load_transcriber_falls_back_to_cpu_when_mps_fails(caplog):
    loader = FakeLoader(fail_on=("mps",))
    transcriber, device, compute_type = cl.load_transcriber(
        loader, "mps", "int8_float16", model="tiny.en"
    )
    assert (device, compute_type) == ("cpu", "int8")
    assert [c[:2] for c in loader.calls] == [("mps", "int8_float16"), ("cpu", "int8")]
    assert transcriber(None) == "text"
    assert "no mps here" in caplog.text


def test_load_transcriber_does_not_fall_back_from_other_devices():
    loader = FakeLoader(fail_on=("cuda",))
    with pytest.raises(RuntimeError):
        cl.load_transcriber(loader, "cuda", "default")
    assert len(loader.calls) == 1


def test_load_transcriber_reports_the_device_auto_picked():
    _t, device, _c = cl.load_transcriber(FakeLoader(reported="cpu"), "auto", "int8")
    assert device == "cpu"


def run_download_only(monkeypatch, loader, system="Darwin", machine="arm64", args=()):
    monkeypatch.setattr(cl.platform, "system", lambda: system)
    monkeypatch.setattr(cl.platform, "machine", lambda: machine)
    out = io.StringIO()
    monkeypatch.setattr(sys, "stdout", out)
    code = cl.main(["--download-only", *args], loader=loader, make_vad=lambda: None)
    return code, [json.loads(line) for line in out.getvalue().splitlines()]


def listener_filters(monkeypatch, *args):
    """Return the drop phrases and filler words `main' gives the Listener."""
    seen = {}
    real = cl.Listener

    def spy(**kw):
        seen.update(kw)
        return real(**kw)

    monkeypatch.setattr(cl, "Listener", spy)
    run_download_only(monkeypatch, FakeLoader(), args=args)
    return seen["drop_phrases"], seen["filler_words"]


def test_main_uses_default_filler_words(monkeypatch):
    drop, fillers = listener_filters(monkeypatch, "--filler-word", "like")
    assert drop == cl.DEFAULT_DROP_PHRASES
    assert fillers == cl.DEFAULT_FILLER_WORDS + ("like",)


def test_no_default_drop_phrases_disables_filler_words(monkeypatch):
    drop, fillers = listener_filters(
        monkeypatch, "--no-default-drop-phrases", "--drop-phrase", "okay", "--filler-word", "um"
    )
    assert drop == ("okay",)
    assert fillers == ("um",)


def test_ready_event_names_device_and_compute_type(monkeypatch):
    code, events = run_download_only(monkeypatch, FakeLoader())
    assert code == 0
    assert events == [{"type": "ready", "device": "mps", "compute_type": "int8_float16"}]


def test_ready_event_after_mps_fallback(monkeypatch):
    code, events = run_download_only(monkeypatch, FakeLoader(fail_on=("mps",)))
    assert code == 0
    assert events == [{"type": "ready", "device": "cpu", "compute_type": "int8"}]


def test_explicit_device_and_compute_type_are_passed_through(monkeypatch):
    loader = FakeLoader()
    code, events = run_download_only(
        monkeypatch, loader, args=("--device", "cpu", "--compute-type", "float32")
    )
    assert loader.calls[0][:2] == ("cpu", "float32")
    assert events == [{"type": "ready", "device": "cpu", "compute_type": "float32"}]


def test_load_failure_on_cpu_is_an_error_event(monkeypatch):
    code, events = run_download_only(
        monkeypatch, FakeLoader(fail_on=("mps", "cpu"))
    )
    assert code == 1
    assert [e["type"] for e in events] == ["error"]
    assert "no cpu here" in events[0]["message"]
