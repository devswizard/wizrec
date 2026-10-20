#!/bin/bash
# UI check (b): Settings ▸ Captions shows the speech-engine picker and the whisper.cpp model
# picker, and detects whisper-cli and the installed model.
#
# The engine, model and binary-path preferences are passed as argument-domain defaults
# (whisper.cpp, automatic model, automatic binary search), so the user's stored choices are
# neither used nor changed. Skips when whisper-cli or a model is not installed.
set -u
. "$(dirname "$0")/lib.sh"

MODELS="$HOME/Library/Application Support/WizRec/models"
WHISPER=$(command -v whisper-cli || true)
[ -z "$WHISPER" ] && [ -x /opt/homebrew/bin/whisper-cli ] && WHISPER=/opt/homebrew/bin/whisper-cli
MODEL=$(ls "$MODELS" 2>/dev/null | grep -m1 '^ggml-.*\.bin$' || true)
if [ -z "$WHISPER" ] || [ -z "$MODEL" ]; then log "SKIP: whisper-cli or a model in $MODELS is missing"; exit 0; fi
MODEL_NAME=${MODEL%.bin}

make_work
gui_lock
open_project -captions.backend whisper.cpp -captions.whisper.model "" -captions.whisper.binaryPath "" || exit 1
ax keys , cmd >/dev/null
wait_until 10 'has_window Settings' && pass "Settings window opened" || fail "no Settings window"
ax toolbar Settings Captions >/dev/null
sleep 1.5   # status is computed asynchronously
texts=$(ax texts Settings)
items=$(ax popup-items Settings)
stop_app
gui_unlock

printf '%s\n' "$texts" > "$WORK/settings-texts.txt"
printf '%s\n' "$items" > "$WORK/settings-model-items.txt"
echo "$texts" | grep -q "radio: Apple Speech" && echo "$texts" | grep -q "radio: whisper.cpp = 1" \
    && pass "engine picker shows Apple Speech and whisper.cpp (selected)" || fail "engine picker missing"
echo "$texts" | grep -qF "Found: $WHISPER" && pass "whisper-cli detected at $WHISPER" || fail "whisper-cli not detected"
echo "$texts" | grep -qF "whisper.cpp is ready." && pass "status: ready" || fail "status not ready"
echo "$items" | grep -q "^Automatic" && echo "$items" | grep -qF "$MODEL_NAME" \
    && pass "model picker lists Automatic and $MODEL_NAME" || fail "model picker lacks $MODEL_NAME"
[ "$FAILURES" -eq 0 ] || { echo "--- texts"; echo "$texts"; echo "--- model items"; echo "$items"; }

[ "$FAILURES" -eq 0 ] && log "settings ▸ captions: all checks passed" || log "settings ▸ captions: $FAILURES failure(s) (work dir $WORK)"
exit "$FAILURES"
