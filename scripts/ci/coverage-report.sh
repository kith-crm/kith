#!/usr/bin/env bash
set -uo pipefail

mix test.coverage
status=$?
case "$status" in
  0) message='Coverage report meets the unchanged 90% target.' ;;
  3) message='Coverage report is informational: line coverage is below the unchanged 90% target. ExUnit failures remain blocking.' ;;
  *) exit "$status" ;;
esac
printf '%s\n' "$message"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '%s\n' "$message" >> "$GITHUB_STEP_SUMMARY"
fi
