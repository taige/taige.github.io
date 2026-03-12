#!/bin/bash
set -euo pipefail

API_BASE="http://127.0.0.1:9090"
CHECK_URL="http://fraud-check.stash/"

# defaults
FRAUD_THRESHOLD=70
FRAUD_WEIGHT=0.6
DELAY_WEIGHT=0.4
AUTO_SELECT=false
SELECT_GROUP=""

urlencode() {
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

api_get() {
  curl -s "${API_BASE}$1"
}

api_put() {
  curl -s -X PUT -H "Content-Type: application/json" -d "$2" "${API_BASE}$1"
}

usage() {
  cat <<'EOF'
Usage: fraud_score_check.sh [GROUP] [OPTIONS]

Options:
  -s, --select              Auto-switch to the best node
  --select-group "name"     Target select group (default: same as GROUP)
  -t, --threshold N         Skip nodes with fraud score >= N (default: 70)
  -fw, --fraud-weight F     Weight for fraud score component (default: 0.6)
  -dw, --delay-weight F     Weight for delay component (default: 0.4)
  -h, --help                Show this help
EOF
  exit 0
}

# parse arguments — first positional arg is TARGET_GROUP
TARGET_GROUP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--select)      AUTO_SELECT=true; shift ;;
    --select-group)   SELECT_GROUP="$2"; shift 2 ;;
    -t|--threshold)   FRAUD_THRESHOLD="$2"; shift 2 ;;
    -fw|--fraud-weight)  FRAUD_WEIGHT="$2"; shift 2 ;;
    -dw|--delay-weight)  DELAY_WEIGHT="$2"; shift 2 ;;
    -h|--help)        usage ;;
    -*)               echo "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$TARGET_GROUP" ]]; then
        TARGET_GROUP="$1"
      else
        echo "Unexpected argument: $1"; usage
      fi
      shift ;;
  esac
done

TARGET_GROUP="${TARGET_GROUP:-手动选择}"
SELECT_GROUP="${SELECT_GROUP:-$TARGET_GROUP}"

# check dependencies
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

if ! command -v bc &>/dev/null; then
  echo "Error: bc is required."
  exit 1
fi

# check Stash API
if ! api_get "/proxies" >/dev/null 2>&1; then
  echo "Error: Cannot connect to Stash API at $API_BASE"
  exit 1
fi

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
echo "Scoring: fraud_weight=$FRAUD_WEIGHT delay_weight=$DELAY_WEIGHT threshold=$FRAUD_THRESHOLD"
echo ""

# collect results: score\ticon\tnode\tip\trisk\tdelay\tfinal
RESULTS=""
INDEX=0
while IFS= read -r node; do
  INDEX=$((INDEX + 1))

  printf "[%d/%d] Testing: %s ... " "$INDEX" "$NODE_COUNT" "$node"

  NODE_ENCODED=$(urlencode "$node")
  RESP=$(curl -s --max-time 15 "${CHECK_URL}?node=${NODE_ENCODED}" 2>/tmp/fraud-check-curl.log || echo "")

  if [[ -z "$RESP" ]] && [[ -f /tmp/fraud-check-curl.log ]]; then
    ERR=$(cat /tmp/fraud-check-curl.log)
    if [[ -n "$ERR" ]]; then
      printf "ERROR: %s\n" "$ERR"
      RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tError\t-\t-1\n"
      continue
    fi
  fi

  if [[ -z "$RESP" ]]; then
    printf "TIMEOUT\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tTimeout\t-\t-1\n"
    continue
  fi

  SCORE=$(echo "$RESP" | jq -r '.fraudScore // empty' 2>/dev/null)
  IP=$(echo "$RESP" | jq -r '.ip // empty' 2>/dev/null)
  ELAPSED=$(echo "$RESP" | jq -r '.elapsed // empty' 2>/dev/null)

  if [[ -z "$SCORE" ]]; then
    printf "NO DATA\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t${IP:-?}\tNo Data\t${ELAPSED:--}\t-1\n"
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

  # calculate final score
  FINAL="-1"
  if [[ -n "$ELAPSED" ]] && (( SCORE < FRAUD_THRESHOLD )); then
    FRAUD_COMP=$(echo "scale=4; (100 - $SCORE) / 100" | bc)
    DELAY_COMP=$(echo "scale=4; d = 1 - $ELAPSED / 1000; if (d < 0) d = 0; d" | bc)
    FINAL=$(echo "scale=2; $FRAUD_WEIGHT * $FRAUD_COMP + $DELAY_WEIGHT * $DELAY_COMP" | bc)
  fi

  DELAY_STR="${ELAPSED:--}ms"
  printf "%s %s (Score: %d, %s, %s, Final: %s)\n" "$ICON" "$IP" "$SCORE" "$RISK" "$DELAY_STR" "$FINAL"
  RESULTS="${RESULTS}${SCORE}\t${ICON}\t${node}\t${IP}\t${RISK}\t${ELAPSED:--}\t${FINAL}\n"

done <<< "$NODES"

# print sorted summary
echo ""
echo "========================================== Summary =========================================="
printf "%-4s %-40s %-16s %5s %7s  %5s  %-6s\n" "" "Node" "IP" "Score" "Delay" "Final" "Risk"
echo "─────────────────────────────────────────────────────────────────────────────────────────────"

BEST_NODE=""
BEST_FINAL="-1"

printf '%b' "$RESULTS" | sort -t$'\t' -k7 -g -r | while IFS=$'\t' read -r score icon node ip risk delay final; do
  if [[ "$delay" == "-" ]]; then
    delay_str="   -"
  else
    delay_str="${delay}ms"
  fi
  if [[ "$final" == "-1" ]]; then
    final_str="    -"
  else
    final_str="$final"
  fi
  printf "%-4s %-40s %-16s %5s %7s  %5s  %-6s\n" "$icon" "$node" "$ip" "$score" "$delay_str" "$final_str" "$risk"
done

# find best node (outside subshell)
BEST_LINE=$(printf '%b' "$RESULTS" | sort -t$'\t' -k7 -g -r | head -1)
BEST_FINAL=$(echo "$BEST_LINE" | cut -d$'\t' -f7)
BEST_NODE=$(echo "$BEST_LINE" | cut -d$'\t' -f3)

echo "─────────────────────────────────────────────────────────────────────────────────────────────"

if [[ "$BEST_FINAL" == "-1" || -z "$BEST_NODE" ]]; then
  echo ""
  echo "No eligible nodes found (all above threshold or failed)."
  exit 0
fi

echo ""
echo "Best node: $BEST_NODE (Final: $BEST_FINAL)"

# auto-select
if [[ "$AUTO_SELECT" == "true" ]]; then
  echo ""
  SELECT_ENCODED=$(urlencode "$SELECT_GROUP")
  SELECT_DATA=$(api_get "/proxies/$SELECT_ENCODED")
  SELECT_TYPE=$(echo "$SELECT_DATA" | jq -r '.type')

  if [[ "$SELECT_TYPE" != "Selector" && "$SELECT_TYPE" != "select" ]]; then
    echo "Error: Group '$SELECT_GROUP' is type '$SELECT_TYPE', not select. Cannot auto-switch."
    exit 1
  fi

  echo "Switching '$SELECT_GROUP' → $BEST_NODE ..."
  PUT_RESP=$(api_put "/proxies/$SELECT_ENCODED" "{\"name\":\"$BEST_NODE\"}")

  # PUT returns empty body on 204 success
  if [[ -z "$PUT_RESP" ]]; then
    echo "Switched successfully."
  else
    echo "Switch response: $PUT_RESP"
  fi
fi
