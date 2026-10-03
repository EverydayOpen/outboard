#!/usr/bin/env bash
# Probes E2, E3 and E4 (BUILD_PLAN section 6.4): what the tools Outboard moves data for do when their data folder points at a drive that is
# not there. The worry is a "ghost" folder: a tool that creates /Volumes/<name> on the boot volume, which would make the guard's
# placeholder or a later mount behave differently (the app itself never creates anything under /Volumes without a UUID check).
#   E2  Ollama CLI (if Homebrew can install it): OLLAMA_MODELS at a missing and at an existing folder.
#   E3  Hugging Face: HF_HUB_CACHE under a missing /Volumes folder and a tiny download.
#   E4  npm, pip and cargo (if present) with their cache folder under the missing /Volumes folder.
# Usage: bash tools/probes/ghost_mount.sh OUTDIR. Needs network (the runners have it). Each step is bounded in time. Every outcome is
# data, so the script exits 0. Never part of the app: the app never writes environment variables, shell files or launch agents.
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${1:-out}
# shellcheck source=tools/probes/lib.sh
. tools/probes/lib.sh
W=$(mktemp -d)
GHOST=/Volumes/outboard-ghostdrive

ghost_state() {   # ghost_state LABEL: is there a folder (or anything) at the ghost path now?
  { echo "== after $1"; ls -lde "$GHOST" 2>&1; ls -la "$GHOST" 2>&1 | head -20; } >> "$OUT/ghost-state.txt"
}
{ echo "== before anything"; ls -lde "$GHOST" 2>&1; ls -la /Volumes; } > "$OUT/ghost-state.txt" 2>&1

# E3 Hugging Face
# Accepted risk: huggingface_hub (PyPI) and ollama (Homebrew) are installed unpinned, because the point is to see what the current releases do and
# fixtures.yml runs this weekly. The job holds contents: read only and no secrets, the probes are data, and nothing from here ships in the app.
if python3 -m venv "$W/venv" > "$OUT/e3-venv.txt" 2>&1 && "$W/venv/bin/pip" install -q huggingface_hub >> "$OUT/e3-venv.txt" 2>&1; then
  rec e3-hf-missing-cache env HF_HUB_CACHE="$GHOST/hub" bounded 240 "$W/venv/bin/python" -c \
    "from huggingface_hub import hf_hub_download; print(hf_hub_download('hf-internal-testing/tiny-random-bert', 'config.json'))"
  ghost_state e3
  rec e3-hf-existing-cache env HF_HUB_CACHE="$W/hf-cache" bounded 240 "$W/venv/bin/python" -c \
    "from huggingface_hub import hf_hub_download; print(hf_hub_download('hf-internal-testing/tiny-random-bert', 'config.json'))"
  rec e3-hf-existing-tree find "$W/hf-cache" -maxdepth 6 -exec ls -ld {} +
else
  note e3-skipped "could not make a Python environment or install huggingface_hub; see e3-venv.txt"
fi

# E4 npm, pip, cargo
if command -v npm > /dev/null 2>&1; then
  rec e4-npm env npm_config_cache="$GHOST/npm" bounded 120 npm view left-pad version
  ghost_state e4-npm
else
  note e4-skipped "npm is not installed on this runner"
fi
if [ -x "$W/venv/bin/pip" ]; then
  rec e4-pip env PIP_CACHE_DIR="$GHOST/pip" bounded 180 "$W/venv/bin/pip" download six -d "$W/pip-dl"
  ghost_state e4-pip
fi
if command -v cargo > /dev/null 2>&1; then
  mkdir -p "$W/crate/src"
  printf '[package]\nname = "tiny"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nitoa = "1"\n' > "$W/crate/Cargo.toml"
  printf 'fn main() {}\n' > "$W/crate/src/main.rs"
  ( cd "$W/crate" && rec e4-cargo env CARGO_HOME="$GHOST/cargo" bounded 240 cargo fetch )
  ghost_state e4-cargo
else
  note e4-skipped "cargo is not installed on this runner"
fi

# E2 Ollama
if command -v ollama > /dev/null 2>&1 || { command -v brew > /dev/null 2>&1 && HOMEBREW_NO_AUTO_UPDATE=1 bounded 900 brew install ollama > "$OUT/e2-brew-install.txt" 2>&1; }; then
  rec e2-ollama-version ollama --version
  for variant in missing existing; do
    if [ "$variant" = missing ]; then models="$GHOST/models"; else models="$W/ollama-models"; mkdir -p "$models"; fi
    env OLLAMA_MODELS="$models" OLLAMA_HOST=127.0.0.1:11999 ollama serve > "$OUT/e2-serve-$variant.txt" 2>&1 &
    pid=$!
    sleep 10
    rec "e2-api-tags-$variant" curl -s -m 10 http://127.0.0.1:11999/api/tags
    rec "e2-list-$variant" env OLLAMA_HOST=127.0.0.1:11999 bounded 30 ollama list
    kill "$pid" 2> /dev/null
    wait "$pid" 2> /dev/null
    ghost_state "e2-$variant"
    note e2-summary "$variant: models folder listing: $(ls -la "$models" 2>&1 | tr '\n' ' ')"
  done
else
  note e2-skipped "the Ollama CLI could not be installed with Homebrew on this runner; see e2-brew-install.txt"
fi

# Whatever a tool created under /Volumes is removed here, so the next probe starts clean (a throwaway runner; the app never does this).
if [ -d "$GHOST" ] && ! mount | grep -qF " on $GHOST "; then rm -rf "$GHOST" 2> /dev/null || true; fi
exit 0
