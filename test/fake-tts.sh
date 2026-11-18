#!/bin/sh
# A stand-in for say, Piper and the audio player in the ERT tests.
# It appends its arguments, one line per run and separated by "|", to
# $CODEC_FAKE_TTS_LOG.  If it gets --output_file FILE, it copies stdin
# to FILE, as Piper does.  Then it sleeps $CODEC_FAKE_TTS_SLEEP seconds
# and exits with $CODEC_FAKE_TTS_EXIT.
log=${CODEC_FAKE_TTS_LOG:-/dev/null}
out=
prev=
line=
for arg; do
  [ "$prev" = --output_file ] && out=$arg
  prev=$arg
  line="$line$arg|"
done
printf '%s\n' "$line" >> "$log"
if [ -n "$out" ]; then cat > "$out"; fi
sleep "${CODEC_FAKE_TTS_SLEEP:-0.2}"
exit "${CODEC_FAKE_TTS_EXIT:-0}"
