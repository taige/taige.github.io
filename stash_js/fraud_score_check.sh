#!/bin/bash
set -euo pipefail

API_BASE="http://127.0.0.1:9090"
CHECK_URL="http://fraud-check.stash/"

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

api_get() {
  curl -s "${API_BASE}$1"
}

# check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

# check Stash API
if ! api_get "/proxies" >/dev/null 2>&1; then
  echo "Error: Cannot connect to Stash API at $API_BASE"
  exit 1
fi

# determine target group
TARGET_GROUP="${1:-手动选择}"

# get nodes from target group
TARGET_ENCODED=$(urlencode "$TARGET_GROUP")
GROUP_DATA=$(api_get "/proxies/$TARGET_ENCODED")
GROUP_TYPE=$(echo "$GROUP_DATA" | jq -r '.type')

if [[ "$GROUP_TYPE" == "null" || -z "$GROUP_TYPE" ]]; then
  echo "Error: Group '$TARGET_GROUP' not found"
  echo ""
  echo "Available groups:"
  api_get "/proxies" | jq -r '.proxies | to_entries[] | select(.value.all != null) | "  \(.key) (\(.value.type), \(.value.all | length) nodes)"'
  exit 1
fi

NODES=$(echo "$GROUP_DATA" | jq -r '.all[]')
NODE_COUNT=$(echo "$GROUP_DATA" | jq '.all | length')

echo "Target group: $TARGET_GROUP ($GROUP_TYPE, $NODE_COUNT nodes)"
echo ""

# collect results
RESULTS=""
INDEX=0
while IFS= read -r node; do
  INDEX=$((INDEX + 1))

  printf "[%d/%d] Testing: %s ... " "$INDEX" "$NODE_COUNT" "$node"

  # request local Stash rewrite endpoint — script fetches ippure via X-Stash-Selected-Proxy
  NODE_ENCODED=$(urlencode "$node")
  RESP=$(curl -s --max-time 15 "${CHECK_URL}?node=${NODE_ENCODED}" 2>/tmp/fraud-check-curl.log || echo "")

  if [[ -z "$RESP" ]] && [[ -f /tmp/fraud-check-curl.log ]]; then
    ERR=$(cat /tmp/fraud-check-curl.log)
    if [[ -n "$ERR" ]]; then
      printf "ERROR: %s\n" "$ERR"
      RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tError\n"
      continue
    fi
  fi

  if [[ -z "$RESP" ]]; then
    printf "TIMEOUT\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tTimeout\n"
    continue
  fi

  SCORE=$(echo "$RESP" | jq -r '.fraudScore // empty' 2>/dev/null)
  IP=$(echo "$RESP" | jq -r '.ip // empty' 2>/dev/null)

  if [[ -z "$SCORE" ]]; then
    printf "NO DATA\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t${IP:-?}\tNo Data\n"
    continue
  fi

  if (( SCORE >= 70 )); then
    RISK="High"
    ICON="🔴"
  elif (( SCORE >= 40 )); then
    RISK="Medium"
    ICON="🟡"
  else
    RISK="Low"
    ICON="🟢"
  fi

  printf "%s %s (Score: %d, %s)\n" "$ICON" "$IP" "$SCORE" "$RISK"
  RESULTS="${RESULTS}${SCORE}\t${ICON}\t${node}\t${IP}\t${RISK}\n"

done <<< "$NODES"

# print sorted summary
echo ""
echo "============================== Summary =============================="
printf "%-4s %-40s %-16s %5s  %-6s\n" "" "Node" "IP" "Score" "Risk"
echo "─────────────────────────────────────────────────────────────────────"

printf "$RESULTS" | sort -t$'\t' -k1 -n -r | while IFS=$'\t' read -r score icon node ip risk; do
  printf "%-4s %-40s %-16s %5s  %-6s\n" "$icon" "$node" "$ip" "$score" "$risk"
done

echo "─────────────────────────────────────────────────────────────────────"
echo ""
