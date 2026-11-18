#!/bin/sh
# A stand-in for codec_listener.py in the ERT tests.  It ignores its
# arguments, speaks the protocol, and takes one test-only command:
# "say TEXT" prints TEXT as an utterance.
echo "fake listener: $*" >&2
if [ -n "$CODEC_FAKE_FAIL" ]; then
  printf '{"type":"error","message":"%s"}\n' "$CODEC_FAKE_FAIL"
  exit 3
fi
echo '{"type":"ready","device":"mps","compute_type":"int8_float16","extra":1}'
echo '{"type":"listening"}'
while IFS= read -r command; do
  case "$command" in
    mute) echo '{"type":"muted"}' ;;
    unmute) echo '{"type":"listening"}' ;;
    "say "*) printf '{"type":"utterance","text":"%s"}\n' "${command#say }" ;;
    noise) echo 'this is not json' ;;
    quit) echo "fake listener: bye" >&2; exit 0 ;;
  esac
done
