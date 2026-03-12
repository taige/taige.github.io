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

# pad string to target display width (handles CJK/emoji)
pad_right() {
  local str="$1" target="$2"
  local dw
  dw=$(python3 -c "
import unicodedata,sys
s=sys.argv[1]
w=0
i=0
while i<len(s):
    c=s[i]
    cp=ord(c)
    if 0xD800<=cp<=0xDBFF and i+1<len(s):
        i+=1
    if 0x1F1E6<=cp<=0x1F1FF:
        w+=2
        i+=1
        if i<len(s) and 0x1F1E6<=ord(s[i])<=0x1F1FF:
            i+=1
        continue
    cat=unicodedata.east_asian_width(c)
    w+=2 if cat in('W','F') else 1
    i+=1
print(w)
" "$str")
  local pad=$((target - dw))
  if (( pad < 0 )); then pad=0; fi
  printf '%s%*s' "$str" "$pad" ""
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

NODES=$(echo "$GROUP_DATA" | jq -r '.all[]' | grep -iv 'local')
NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')

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
      RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tError\t-\t-1\t-\n"
      continue
    fi
  fi

  if [[ -z "$RESP" ]]; then
    printf "TIMEOUT\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tTimeout\t-\t-1\t-\n"
    continue
  fi

  SCORE=$(echo "$RESP" | jq -r '.fraudScore // empty' 2>/dev/null)
  IP=$(echo "$RESP" | jq -r '.ip // empty' 2>/dev/null)
  COUNTRY_CODE=$(echo "$RESP" | jq -r '.countryCode // empty' 2>/dev/null)

  # get delay from Clash API (cached value first, fallback to real-time test)
  NODE_DELAY=$(api_get "/proxies/$NODE_ENCODED" | jq -r '.delay // 0' 2>/dev/null)
  if [[ -z "$NODE_DELAY" || "$NODE_DELAY" == "0" ]]; then
    NODE_DELAY=$(api_get "/proxies/$NODE_ENCODED/delay?timeout=5000&url=http://cp.cloudflare.com/generate_204" | jq -r '.delay // empty' 2>/dev/null)
  fi

  if [[ -z "$SCORE" ]]; then
    printf "NO DATA\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t${IP:-?}\tNo Data\t${NODE_DELAY:--}\t-1\t-\n"
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

  # calculate final score (weighted geometric mean + exponential delay decay)
  FINAL="-1"
  if [[ -n "$NODE_DELAY" && "$NODE_DELAY" != "0" ]] && (( SCORE < FRAUD_THRESHOLD )); then
    FRAUD_COMP=$(echo "scale=4; (100 - $SCORE) / 100" | bc)
    DELAY_COMP=$(echo "scale=4; e(-$NODE_DELAY / 500)" | bc -l)
    FINAL=$(echo "scale=4; e($FRAUD_WEIGHT * l($FRAUD_COMP) + $DELAY_WEIGHT * l($DELAY_COMP))" | bc -l)
  fi

  DELAY_STR="${NODE_DELAY:--}ms"
  printf "%s %s (Score: %d, %s, %s, Final: %s)\n" "$ICON" "$IP" "$SCORE" "$RISK" "$DELAY_STR" "$FINAL"
  RESULTS="${RESULTS}${SCORE}\t${ICON}\t${node}\t${IP}\t${RISK}\t${NODE_DELAY:--}\t${FINAL}\t${COUNTRY_CODE:--}\n"

done <<< "$NODES"

# print sorted summary
echo ""
echo "========================================== Summary =========================================="
printf "     %-44s %-16s %5s  %-6s %7s  %6s\n" "Node" "IP" "Score" "Risk" "Delay" "Final"
echo "─────────────────────────────────────────────────────────────────────────────────────────────"

BEST_NODE=""
BEST_FINAL="-1"

printf '%b' "$RESULTS" | sort -t$'\t' -k7 -g -r | while IFS=$'\t' read -r score icon node ip risk delay final cc; do
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
  if [[ "$cc" != "-" && -n "$cc" ]]; then
    display_node="[$cc]$node"
  else
    display_node="$node"
  fi
  node_padded=$(pad_right "$icon $display_node" 48)
  printf '%s %-16s %5s  %-6s %7s  %6s\n' "$node_padded" "$ip" "$score" "$risk" "$delay_str" "$final_str"
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
