#!/usr/bin/env bash
# run_all.sh — Unified Test Runner for Claude Code Agent Fleet
# Runs Guardrails, Hooks Test, Xixi Hooks Test, and Hook E2E in strict mode.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
STRICT=1

echo "================================================================================"
echo "          CLAUDE CODE AGENT FLEET — UNIFIED TEST SUITE RUNNER"
echo "================================================================================"
echo "Working directory: $REPO_ROOT"
echo

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

run_suite() {
  local name="$1" cmd="$2"
  TOTAL_SUITES=$((TOTAL_SUITES + 1))
  echo ">>> [SUITE $TOTAL_SUITES] $name"
  if eval "$cmd"; then
    PASSED_SUITES=$((PASSED_SUITES + 1))
    echo ">>> [PASS] $name"
  else
    FAILED_SUITES=$((FAILED_SUITES + 1))
    echo ">>> [FAIL] $name" >&2
  fi
  echo "--------------------------------------------------------------------------------"
}

cd "$REPO_ROOT"

run_suite "Guardrails (Strict Mode)" "bash tests/guardrails.sh --strict"
run_suite "Bash Mutator Gate Tests (hooks.test.sh)" "bash tests/hooks.test.sh"
run_suite "Xixi Write Sandbox & Clipboard Tests (xixi-hooks.test.sh)" "bash tests/xixi-hooks.test.sh"
run_suite "Hook Registration & E2E Tests (hook-e2e.test.sh)" "bash tests/hook-e2e.test.sh"

echo
echo "================================================================================"
echo "TEST SUITE SUMMARY: $PASSED_SUITES/$TOTAL_SUITES passed, $FAILED_SUITES failed"
echo "================================================================================"

if [[ "$FAILED_SUITES" -eq 0 ]]; then
  echo "✅ ALL TEST SUITES PASSED SUCCESSFULLY."
  exit 0
else
  echo "❌ TEST SUITE FAILURES DETECTED." >&2
  exit 1
fi
