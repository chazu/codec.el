# codec.el

Hands-free voice input for [agent-shell](https://github.com/xenodium/agent-shell).
Turn on `codec-mode`, speak, pause. The pause sends what you said to the
agent. Everything runs on your machine.

[![License: GPL v3+](https://img.shields.io/badge/License-GPL%20v3%2B-blue.svg)](LICENSE)

Status: the input side works (you speak, the agent gets a prompt).
Spoken replies are the next step; see [Next: spoken replies via
TTS](#next-spoken-replies-via-tts).

## How it works

```
mic ─► listener (Python) ─► JSON lines ─► codec-mode (Emacs) ─► agent-shell
        Silero VAD                         adds the voice preamble,
        faster-whisper                     queues while the agent works
```

1. `codec-mode` starts `listener/codec_listener.py` as a subprocess.
2. The listener reads the microphone. Silero VAD finds speech. After
   900 ms of silence (`codec-silence-ms`) the utterance ends.
3. faster-whisper transcribes the utterance. The listener drops empty
   transcripts and the phrases Whisper invents on silence ("you",
   "Thank you.").
4. codec adds `codec-voice-preamble` to the transcript and submits it
   in the target agent-shell buffer. If the agent is in a turn, codec
   queues the utterance and sends it when the turn completes.

## Requirements

- Emacs 29.1 or later, with agent-shell.
- [uv](https://docs.astral.sh/uv/). uv installs Python and the
  listener's packages. The listener works with Python 3.12 or later and
  is pinned to 3.14 in `listener/.python-version`.
- A microphone. Tested on macOS on Apple Silicon. The sounddevice wheel
  includes PortAudio on macOS; on Linux, install PortAudio
  (`libportaudio2`).

## Installation

### straight.el and use-package

```elisp
(use-package codec
  :straight (codec :type git :host github :repo "chazu/codec.el")
  :after agent-shell
  :commands (codec-mode codec-set-target codec-mute codec-unmute)
  :init
  ;; A USB foot pedal that sends S-<f12>:
  (keymap-global-set "S-<f12>" #'codec-mode))
```

straight links only the `.el` files into its build directory. codec
follows the symlink of `codec.el` back to the repository and finds
`listener/` there. If you install codec another way, set
`codec-listener-directory` to the `listener` directory of your copy.

### Manual

Clone the repository, add it to `load-path`, and `(require 'codec)`.

### First run: Python packages and the Whisper model

The listener keeps its virtual environment in `listener/.venv`, inside
the package directory, managed by uv. Whisper models go to the Hugging
Face cache (`~/.cache/huggingface/hub`). Both need network access
once; after that, codec works offline.

Do one of these:

- `M-x codec-download-model`. It runs uv and downloads `codec-model`
  in a compilation buffer.
- From the repository (for straight,
  `~/.emacs.d/straight/repos/codec.el`): `make model`.

If you skip this step, the first `codec-mode` does the same work. The
mode line shows `Codec:…` until the model is loaded.

### macOS: Microphone permission

macOS gives microphone access per app. The listener is a child process
of Emacs, so it uses the permission of Emacs.app (or of your terminal,
if Emacs runs in a terminal).

1. Turn on `codec-mode`. macOS asks whether Emacs can use the
   microphone. Click **Allow**.
2. If you get no prompt, open **System Settings → Privacy & Security →
   Microphone** and turn on Emacs.

Without the permission, macOS does not give an error. The listener
gets silence and nothing happens. To ask again, run
`tccutil reset Microphone org.gnu.Emacs` and restart Emacs. If Emacs is
not in the list at all, your Emacs build may lack
`NSMicrophoneUsageDescription` in its `Info.plist`.

## Usage

| Command            | What it does                                                  |
|--------------------|---------------------------------------------------------------|
| `codec-mode`       | Toggle voice input. Starts or stops the listener.             |
| `codec-set-target` | Send voice prompts to another agent-shell buffer.             |
| `codec-mute`       | Stop sending. The listener discards audio.                    |
| `codec-unmute`     | Start sending again.                                          |
| `codec-download-model` | Install the listener's packages and download the model.   |

codec binds no keys. For a foot pedal that sends `S-<f12>`:

```elisp
(keymap-global-set "S-<f12>" #'codec-mode)
```

To find what your pedal sends, press `C-h k` and then the pedal.

**Target.** When you turn on `codec-mode`, the target is the current
agent-shell buffer, or else the agent-shell buffer you selected most
recently. If there is no agent-shell buffer, codec starts muted. If the
target buffer is killed, codec shows a message and stays muted until
you run `codec-set-target`.

**Cancel.** Say "scratch that" or "cancel" (`codec-cancel-phrases`) as
a whole utterance. codec sends nothing, discards queued utterances, and
shows `codec: discarded`.

**Mode line.**

| Text          | State     |
|---------------|-----------|
| `Codec:…`     | starting: loading the model |
| `Codec:on`    | listening |
| `Codec:muted` | muted     |
| `Codec:err`   | the listener stopped; see `*codec-listener-log*` |

The listener's stderr and codec's own log go to `*codec-listener-log*`.

## Configuration

```elisp
(use-package codec
  :straight (codec :type git :host github :repo "chazu/codec.el")
  :custom
  (codec-model "base.en")               ; faster, less accurate
  (codec-silence-ms 1200)               ; wait longer before sending
  (codec-drop-phrases '("okay"))        ; more noise to drop
  (codec-device 'cpu)                   ; skip the Apple GPU
  (codec-cancel-phrases '("scratch that" "never mind"))
  :init
  (keymap-global-set "S-<f12>" #'codec-mode))
```

| Option                      | Default         | Purpose |
|-----------------------------|-----------------|---------|
| `codec-model`               | `"small.en"`    | faster-whisper model name or path. |
| `codec-device`              | `auto`          | `auto`, `mps`, `cpu`, or another CTranslate2 device. |
| `codec-compute-type`        | `auto`          | `auto`, or a CTranslate2 compute type such as `int8`. |
| `codec-silence-ms`          | `900`           | Silence that ends an utterance. |
| `codec-drop-phrases`        | `nil`           | Transcripts to drop, besides the built-in list. |
| `codec-listener-extra-args` | `nil`           | More listener options (`--help` lists them). |
| `codec-voice-preamble`      | see below       | Instructions added to each voice prompt. `%o`/`%c` are the tags. |
| `codec-preamble-position`   | `prepend`       | `prepend` or `append` the preamble. |
| `codec-spoken-open`         | `"<spoken>"`    | Tag that opens the spoken summary. |
| `codec-spoken-close`        | `"</spoken>"`   | Tag that closes the spoken summary. |
| `codec-cancel-phrases`      | `("scratch that" "cancel")` | Utterances that discard instead of send. |
| `codec-mode-line-states`    | see above       | Mode line text for each state. |
| `codec-after-send-functions`| `nil`           | Called with the buffer and transcript after each voice prompt. |
| `codec-uv-program`          | `"uv"`          | The uv executable. |
| `codec-listener-directory`  | `nil` (auto)    | Where `codec_listener.py` is. |
| `codec-listener-command`    | `nil` (uv)      | Run the listener with another command. |
| `codec-shutdown-timeout`    | `2`             | Seconds to wait for the listener to quit. |

### The voice preamble

Only voice prompts get the preamble. Typed prompts stay as they are. The
default:

> [voice] The user is speaking to you hands-free and will hear only a
> short spoken summary. Answer normally in full. Then end your reply
> with `<spoken>`one or two plain, speakable sentences: the result and
> the one thing the user should do next`</spoken>`. No code, paths or
> markdown inside `<spoken>`. The transcript below may have
> speech-recognition errors.

### Model choice

The listener uses **faster-whisper** (CTranslate2), not mlx-whisper:

- Utterances are short, and the models are small (`small.en`,
  `base.en`). CTranslate2's Metal backend (below) makes them fast on
  Apple Silicon. The GPU speed of mlx-whisper matters most for long
  audio and large models.
- faster-whisper ships the Silero VAD model as ONNX. The listener runs
  it with onnxruntime, so there is no PyTorch download.
- It runs the same on Linux and macOS.

### Apple Silicon

On macOS on Apple Silicon, `codec-device` `auto` uses CTranslate2's
experimental Metal backend (`mps`). CTranslate2's own `auto` never
picks it, so the listener does. Elsewhere, `auto` is CTranslate2's
choice (CUDA or the CPU).

`codec-compute-type` `auto` means `int8_float16` on `mps` (CTranslate2
runs it as `float16`) and `int8` on the CPU.

Measured with `small.en` on a 7.3 s clip, on one Apple Silicon Mac
(2026-11-18). All three gave the same transcript:

| Device and compute type | First run | Best run |
|-------------------------|-----------|----------|
| `cpu`, `int8`           |           | 1.19 s   |
| `mps`, `float16`        | 0.84 s    | 0.38 s   |
| `mps`, `int8_float16`   | 0.40 s    | 0.38 s   |

If the model does not load on `mps`, the listener logs the reason and
uses `cpu` with `int8`. The `ready` event and `*codec-listener-log*`
show the device it uses. To use the CPU always:

```elisp
(setq codec-device 'cpu)
```

From a shell, give the listener `--device cpu`.

## Listener protocol

The listener is a plain program; you can run it from a shell:

```sh
uv run --project listener python listener/codec_listener.py --help
```

**Stdout** has one JSON object per line and nothing else:

```json
{"type":"ready","device":"mps","compute_type":"int8_float16"}
{"type":"listening"}
{"type":"muted"}
{"type":"stopped"}
{"type":"utterance","text":"Run the tests and tell me what failed."}
{"type":"error","message":"microphone failed: ..."}
```

`ready` comes once, after the model loads. It names the device the
model runs on and the compute type. Readers must ignore keys they do
not know. `listening`, `muted` and
`stopped` come after each state change. An `error` followed by exit is
fatal; other errors (one bad transcription) are not.

**Stdin** takes one command per line:

| Command  | Effect |
|----------|--------|
| `mute`   | Discard audio and any utterance in progress. |
| `unmute` | Listen again. |
| `stop`   | Stop capture, and transcribe the utterance in progress. |
| `start`  | Start capture. |
| `quit`   | Exit. End of file on stdin also exits. |

`start` and `stop` are the seam for a later push-to-talk mode: start the
listener with `--no-autostart`, send `start` on key press and `stop` on
key release. codec does not use them yet.

**Stderr** has the logs.

## Development

```sh
make deps    # uv sync into listener/.venv
make test    # ERT tests and Python tests; no microphone or model needed
make lint    # byte-compile with warnings as errors, checkdoc, package-lint
```

`make lint` runs package-lint when it finds it in straight's or
package.el's directory, or in `PACKAGE_LINT_DIR`.

The ERT tests use `test/fake-listener.sh` in place of the listener and
stub the agent-shell functions. The Python tests feed synthetic frames
and fake models to the listener.

## Known issues

- With faster-whisper 1.2.1 and the PyAV in `listener/uv.lock`,
  `WhisperModel.transcribe` on a file path fails with `TypeError:
  open() got an unexpected keyword argument 'metadata_errors'`; the
  listener gives it NumPy arrays, so it is not affected.

## Next: spoken replies via TTS

The next step makes the agent talk back. The plan:

1. On agent-shell's `turn-complete` event after a voice prompt (see
   `codec-after-send-functions`), find the text between
   `codec-spoken-open` and `codec-spoken-close` in the reply.
2. Send that text to a local TTS process, Piper or Kokoro.
3. Call `codec-mute` while it speaks, so the listener does not
   transcribe the speech, and `codec-unmute` after.
4. Add a barge-in command that stops speech and unmutes at once.
5. Optionally hide the spoken block in the buffer.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
