#!/usr/bin/env bash
# Run every suite in this directory under a headless nvim and aggregate the totals.
#
# The suites are bespoke and report in two different shapes: most write "N passed, M failed" to a
# file named by their own REPORT constant, and test_chat_edit prints "N assertions, M failures" on
# stdout. The report path is read out of each suite rather than hardcoded here, so a suite that
# changes where it writes does not silently get counted against a stale file from another run.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
NVIM=${NVIM:-nvim}
suites=(tests/test_*.lua)
[ "$#" -gt 0 ] && suites=("$@")

total_pass=0 total_fail=0 failed=()

for suite in "${suites[@]}"; do
  name=$(basename "$suite" .lua)
  report=$(grep -oE 'REPORT *= *"[^"]*"' "$suite" | head -1 | sed -E 's/.*"(.*)"/\1/')
  [ -n "$report" ] && rm -f "$report"

  # `-c luafile` rather than `-l`: script mode never enters the main loop, so a suite that drives
  # a prompt with nvim_feedkeys (test_say's ui.confirm cases) dies mid-run instead of failing.
  out=$("$NVIM" --headless --noplugin -u tests/minimal_init.lua -c "luafile $suite" -c "qa!" 2>&1)

  pass="" fail=""
  if [ -n "$report" ] && [ -f "$report" ]; then
    line=$(grep -aoE '[0-9]+ passed, [0-9]+ failed' "$report" | tail -1)
    pass=${line%% *}
    fail=$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failed/\1/')
  else
    line=$(printf '%s\n' "$out" | grep -aoE '[0-9]+ assertions, [0-9]+ failures' | tail -1)
    total=${line%% *}
    fail=$(printf '%s' "$line" | sed -E 's/.*, ([0-9]+) failures/\1/')
    [ -n "$total" ] && pass=$((total - fail))
  fi

  if [ -z "$pass" ]; then
    printf '  %-24s NO RESULT\n' "$name"
    printf '%s\n' "$out" | grep -aE 'FAIL|Error|E[0-9]{3,}' | head -5 | sed 's/^/      /'
    failed+=("$name")
    continue
  fi

  total_pass=$((total_pass + pass))
  total_fail=$((total_fail + fail))
  printf '  %-24s %d passed, %d failed\n' "$name" "$pass" "$fail"
  if [ "$fail" -ne 0 ]; then
    failed+=("$name")
    { [ -n "$report" ] && grep -aE 'FAIL' "$report"; printf '%s\n' "$out" | grep -aE 'FAIL'; } | head -8 | sed 's/^/      /'
  fi
done

printf '\n%d passed, %d failed across %d suites\n' "$total_pass" "$total_fail" "${#suites[@]}"
if [ "${#failed[@]}" -ne 0 ]; then
  printf 'failing: %s\n' "${failed[*]}"
  exit 1
fi
