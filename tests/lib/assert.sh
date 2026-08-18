#!/usr/bin/env bash
# assert.sh — Shared Test Assertions and Test Sandbox Harness for Agent Tests
set -uo pipefail

TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0

assert_pass() {
  local desc="$1"
  TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
  echo "PASS  $desc"
}

assert_fail() {
  local desc="$1" detail="${2:-}"
  TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
  if [[ -n "$detail" ]]; then
    echo "FAIL  $desc :: $detail" >&2
  else
    echo "FAIL  $desc" >&2
  fi
}

assert_exit_code() {
  local desc="$1" actual="$2" expected="$3" out="${4:-}"
  if [[ "$actual" -eq "$expected" ]]; then
    assert_pass "$desc"
  else
    local first_out
    first_out=$(printf '%s' "$out" | head -1)
    assert_fail "$desc (exit=$actual, want=$expected)" "$first_out"
  fi
}

assert_output_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    assert_pass "$desc"
  else
    assert_fail "$desc" "missing '$needle'"
  fi
}

assert_output_empty() {
  local desc="$1" out="$2"
  if [[ -z "$out" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc" "unexpected output: $(printf '%s' "$out" | head -1)"
  fi
}

assert_file_missing() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" && ! -L "$path" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc" "path still exists ($path)"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc" "file missing ($path)"
  fi
}

test_report_and_exit() {
  echo
  echo "==> result: $TEST_PASS_COUNT passed, $TEST_FAIL_COUNT failed"
  if [[ "$TEST_FAIL_COUNT" -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}
