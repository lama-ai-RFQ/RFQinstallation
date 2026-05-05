#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/setup.iss"
fail=0

if [ ! -f "$FILE" ]; then
  echo "FAIL: SETUP - setup.iss not found at $FILE"
  exit 1
fi

assert_absent() {
  local id="$1"
  local pattern="$2"
  local message="$3"
  local output
  local status

  output="$(rg -n "$pattern" "$FILE" 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    echo "FAIL: $id - $message"
    printf '%s\n' "$output"
    fail=1
  elif [ "$status" -eq 1 ]; then
    echo "PASS: $id - $message"
  else
    echo "FAIL: $id - rg error while checking $message"
    printf '%s\n' "$output"
    fail=1
  fi
}

assert_absent_i() {
  local id="$1"
  local pattern="$2"
  local message="$3"
  local output
  local status

  output="$(rg -n -i "$pattern" "$FILE" 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    echo "FAIL: $id - $message"
    printf '%s\n' "$output"
    fail=1
  elif [ "$status" -eq 1 ]; then
    echo "PASS: $id - $message"
  else
    echo "FAIL: $id - rg error while checking $message"
    printf '%s\n' "$output"
    fail=1
  fi
}

assert_present() {
  local id="$1"
  local pattern="$2"
  local message="$3"
  local output
  local status

  output="$(rg -n "$pattern" "$FILE" 2>&1)"
  status=$?

  if [ "$status" -eq 0 ]; then
    echo "PASS: $id - $message"
  elif [ "$status" -eq 1 ]; then
    echo "FAIL: $id - $message"
    fail=1
  else
    echo "FAIL: $id - rg error while checking $message"
    printf '%s\n' "$output"
    fail=1
  fi
}

assert_absent \
  "T1" \
  "CheckOpenSSLInPath|CheckOpenSSLInstalled" \
  "setup.iss contains no orphan OpenSSL helper identifiers"

assert_absent_i \
  "T2" \
  "openssl|where openssl|slproweb" \
  "setup.iss contains no stale OpenSSL user-facing text"

assert_present \
  "T4" \
  "if \(not CheckPostgreSQLInPath\(\)\) or \(not CheckPythonInstalled\(\)\) then" \
  "Next-button gate keeps PostgreSQL/Python checks without OpenSSL"

assert_present \
  "T5" \
  "if CheckPostgreSQLInPath\(\) and CheckPythonInstalled\(\) then" \
  "footer all-clear condition keeps PostgreSQL/Python checks without OpenSSL"

exit "$fail"
