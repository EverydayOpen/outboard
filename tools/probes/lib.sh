#!/usr/bin/env bash
# Sourced by the probe scripts in this folder (fixtures.yml runs them on macOS runners). Never part of the app.
# A probe records what a command did: NAME.stdout, NAME.stderr and NAME.exit under $OUT. A refusal or a crash is the data, so
# nothing here ever fails the step. Plain bash 3.2 syntax (the macOS runners' /bin/bash).

OUT=${OUT:-out}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)   # absolute: some probes cd into a scratch folder

# rec NAME COMMAND...   run the command, keep its stdout, stderr and exit status
rec() {
  local n=$1 rc=0
  shift
  "$@" > "$OUT/$n.stdout" 2> "$OUT/$n.stderr" || rc=$?
  echo "$rc" > "$OUT/$n.exit"
  return 0
}

# bounded SECONDS COMMAND...   run the command and kill it with SIGALRM after SECONDS (macOS has no timeout(1))
bounded() {
  local s=$1
  shift
  perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$s" "$@"
}

# note NAME TEXT...   append a line to $OUT/NAME.txt
note() {
  local n=$1
  shift
  printf '%s\n' "$*" >> "$OUT/$n.txt"
}

# retry COMMAND...   up to 5 attempts, 5 s then 10 s ... between them (hosted runners answer "Resource busy" now and then)
retry() {
  local i
  for i in 1 2 3 4 5; do
    "$@" && return 0
    sleep $((i * 5))
  done
  return 1
}
