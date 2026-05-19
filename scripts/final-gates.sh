#!/usr/bin/env sh
set -eu

scripts/validate.sh

health_json="$(node voice/dist/index.js health)"
printf '%s\n' "$health_json"
case "$health_json" in
  *'"name":"credentials","status":"ok"'*) ;;
  *)
    echo "Codex ChatGPT auth is not ready. Run codex login, then rerun this script." >&2
    exit 1
    ;;
esac

scripts/claude-review.sh

echo "Automated release gates passed. Run scripts/voice-smoke.sh for the live microphone transcription gate."
