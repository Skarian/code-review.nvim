#!/usr/bin/env sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
NODE_BIN="${NODE:-node}"
HELPER="$ROOT/voice/dist/index.js"
MAX_MS="${CODE_REVIEW_VOICE_SMOKE_MAX_MS:-60000}"
TRANSCRIBE_TIMEOUT_MS="${CODE_REVIEW_VOICE_SMOKE_TRANSCRIBE_TIMEOUT_MS:-120000}"
AUDIO="$(mktemp -t code-review-voice-smoke.XXXXXX.wav)"
FIFO="$(mktemp -u -t code-review-voice-smoke.XXXXXX.fifo)"

cleanup() {
  rm -f "$AUDIO" "$FIFO"
}
trap cleanup EXIT INT TERM

if [ ! -f "$HELPER" ]; then
  echo "Voice helper missing: run npm ci --prefix voice && npm run build --prefix voice" >&2
  exit 1
fi

health_json="$("$NODE_BIN" "$HELPER" health)"
printf '%s\n' "$health_json"
case "$health_json" in
  *'"name":"credentials","status":"ok"'*) ;;
  *)
    echo "Codex ChatGPT auth is not ready. Run codex login, then rerun this script." >&2
    exit 1
    ;;
esac

mkfifo "$FIFO"
devices_json="$("$NODE_BIN" "$HELPER" devices --json || true)"
printf '%s\n' "$devices_json"
if [ -n "${CODE_REVIEW_VOICE_AUDIO_DEVICE:-}" ]; then
  echo "Using microphone: $CODE_REVIEW_VOICE_AUDIO_DEVICE"
  "$NODE_BIN" "$HELPER" record --out "$AUDIO" --max-ms "$MAX_MS" --audio-device "$CODE_REVIEW_VOICE_AUDIO_DEVICE" --jsonl < "$FIFO" &
else
  "$NODE_BIN" "$HELPER" record --out "$AUDIO" --max-ms "$MAX_MS" --jsonl < "$FIFO" &
fi
record_pid=$!

exec 3>"$FIFO"
echo "Recording. Speak now, then press Enter to stop."
IFS= read -r _
printf 'stop\n' >&3
exec 3>&-

wait "$record_pid"
"$NODE_BIN" "$HELPER" transcribe --input "$AUDIO" --timeout-ms "$TRANSCRIBE_TIMEOUT_MS" --json
