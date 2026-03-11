#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-https://pay.batterysos.app}"

red() { printf "\033[31m%s\033[0m\n" "$1"; }
green() { printf "\033[32m%s\033[0m\n" "$1"; }

check_json_ok() {
  local url="$1"
  local body
  body=$(curl -fsS "$url") || { red "FAIL $url"; return 1; }
  echo "$body"
  echo "$body" | grep -q '"ok":true' && green "PASS $url" || { red "FAIL $url"; return 1; }
}

check_200() {
  local url="$1"
  local code
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  if [[ "$code" == "200" ]]; then
    green "PASS $url -> 200"
  else
    red "FAIL $url -> $code"
    return 1
  fi
}

echo "Running launch preflight against: $BASE_URL"

check_json_ok "$BASE_URL/api/billing/status"
check_200 "$BASE_URL/downloads/battery-sos-macos.dmg"
check_200 "$BASE_URL/downloads/battery-sos-macos.dmg.sha256"

green "Preflight checks passed."
