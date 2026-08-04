#!/usr/bin/env bash
# Install the newest torch that is actually usable on every GPU ComfyPod
# targets, then freeze what won into a constraints file.
#
# Each candidate is INSTALLED AND THEN VERIFIED; a candidate is only accepted
# once verify-torch.py says it covers the required architectures. An earlier
# version of this logic accepted a candidate merely because pip exited 0,
# which let an unusable build through and failed the build at the later gate
# instead of simply trying the next candidate.
#
# Usage: install-torch.sh <venv> <index-url(s)> <constraints-out>
# Candidates come from TORCH_CANDIDATES (newline- or '|'-separated), newest
# first; the last one should be a known-good fallback. The index argument may
# list several indexes separated by whitespace or '|' — they are tried in
# order, so a CUDA 13 build can be preferred with an automatic fall back to
# CUDA 12.8 if that index has nothing usable.

set -uo pipefail

VENV="${1:?usage: install-torch.sh <venv> <index-url(s)> <constraints-out>}"
INDEXES="${2:?missing index url}"
CONSTRAINTS="${3:?missing constraints output path}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$VENV/bin/python"

# Newest first. torchvision pins torch exactly (0.28.0 -> 2.13.0, 0.27.1 ->
# 2.12.1, 0.26.0 -> 2.11.0), so the pairs are not interchangeable. torchaudio
# stops at 2.11.0 and, from that release on, declares no torch pin at all —
# whether it really loads against a newer torch is settled by verify-torch.py
# importing it, not by guesswork here.
: "${TORCH_CANDIDATES:=torch==2.13.0 torchvision==0.28.0 torchaudio==2.11.0
torch==2.12.1 torchvision==0.27.1 torchaudio==2.11.0
torch==2.11.0 torchvision==0.26.0 torchaudio==2.11.0
torch torchvision torchaudio
torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1
torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0}"

say() { printf '\n=== %s\n' "$*"; }

winner="" winner_index=""
for INDEX in ${INDEXES//|/ }; do
    say "index: $INDEX"
    # Purely informational: if every candidate fails, this listing is what
    # tells us what to pin instead, without another round-trip through CI.
    "$VENV/bin/pip" index versions torch --index-url "$INDEX" 2>&1 | head -5 \
        || echo "(could not list versions; continuing)"

    # shellcheck disable=SC2001
    while IFS= read -r spec; do
        spec="$(echo "$spec" | sed 's/^ *//; s/ *$//')"
        [ -z "$spec" ] && continue

        say "candidate: $spec"
        # shellcheck disable=SC2086
        if ! uv pip install --python "$PY" $spec --index-url "$INDEX"; then
            echo "-> not installable from this index, trying next"
            continue
        fi
        if ! "$PY" "$HERE/verify-torch.py"; then
            echo "-> installed but not usable on the targeted GPUs, trying next"
            continue
        fi
        winner="$spec"; winner_index="$INDEX"
        break
    done <<< "${TORCH_CANDIDATES//|/$'\n'}"

    [ -n "$winner" ] && break
    say "nothing usable on $INDEX — falling back to the next index"
done

if [ -z "$winner" ]; then
    say "FAILED: no candidate on any index produced a torch usable on sm_120 + sm_89"
    echo "Pin a known-good combination via the TORCH_CANDIDATES build arg."
    echo "The version listings above show what each index actually offers."
    exit 1
fi

say "accepted: $winner (from $winner_index)"
"$VENV/bin/pip" freeze 2>/dev/null | grep -iE '^(torch|torchvision|torchaudio)==' > "$CONSTRAINTS"
echo "froze constraints (the guard that stops nodes downgrading torch):"
cat "$CONSTRAINTS"
