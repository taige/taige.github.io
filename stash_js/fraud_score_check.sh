#!/bin/bash
set -euo pipefail

API_BASE="http://127.0.0.1:9090"
CHECK_URL="http://fraud-check.stash/"

# defaults
FRAUD_THRESHOLD=70
FRAUD_WEIGHT=0.5
DELAY_WEIGHT=0.3
LATENCY_WEIGHT=0.2
AUTO_SELECT=false
SELECT_GROUP=""
REQ_TIMEOUT=3

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
  -fw, --fraud-weight F     Weight for fraud score component (default: 0.5)
  -dw, --delay-weight F     Weight for delay component (default: 0.3)
  -lw, --latency-weight F   Weight for latency component (default: 0.2)
  --timeout N               Request timeout in seconds (default: 3)
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
    -lw|--latency-weight) LATENCY_WEIGHT="$2"; shift 2 ;;
    --timeout)        REQ_TIMEOUT="$2"; shift 2 ;;
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

# fetch all proxies once (used for resolve, group info, cached delay)
ALL_PROXIES=$(api_get "/proxies" 2>/dev/null)
if [[ -z "$ALL_PROXIES" ]]; then
  echo "Error: Cannot connect to Stash API at $API_BASE"
  exit 1
fi

# resolve leaf nodes in a single jq call (recursive, with cycle detection)
# outputs: leaf_node\ttop_level_member\tdelay (tab-separated)
resolve_nodes_jq() {
  echo "$ALL_PROXIES" | jq -r --arg group "$1" '
    def resolve(g; top; visited):
      if (visited | index(g)) then empty
      else
        (visited + [g]) as $v |
        (.proxies[g].all // [])[] as $member |
        (if top == "" then $member else top end) as $t |
        .proxies[$member] as $p |
        if ($p.type == "Direct" or $p.type == "Reject") then empty
        elif ($p | has("all")) then resolve($member; $t; $v)
        else "\($member)\t\($t)\t\($p.delay // 0)"
        end
      end;
    resolve($group; ""; [])
  '
}

# lookup: find the top-level member for a given leaf node
lookup_top_member() {
  echo "$NODE_MAP" | grep -m1 -F "$(printf '%s\t' "$1")" | cut -f2
}

# get nodes from target group
GROUP_DATA=$(echo "$ALL_PROXIES" | jq --arg g "$TARGET_GROUP" '.proxies[$g]')
GROUP_TYPE=$(echo "$GROUP_DATA" | jq -r '.type')

if [[ "$GROUP_TYPE" == "null" || -z "$GROUP_TYPE" ]]; then
  echo "Error: Group '$TARGET_GROUP' not found"
  echo ""
  echo "Available groups:"
  echo "$ALL_PROXIES" | jq -r '.proxies | to_entries[] | select(.value.all != null) | "  \(.key) (\(.value.type), \(.value.all | length) nodes)"'
  exit 1
fi

echo "Resolving nodes from '$TARGET_GROUP' ..."
NODE_MAP=$(resolve_nodes_jq "$TARGET_GROUP" | grep -iv 'local' | awk -F'\t' '!seen[$1]++')
NODES=$(echo "$NODE_MAP" | cut -f1 | sort -u)
NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')

echo "Target group: $TARGET_GROUP ($GROUP_TYPE, $NODE_COUNT nodes)"
echo "Scoring: fraud_weight=$FRAUD_WEIGHT delay_weight=$DELAY_WEIGHT latency_weight=$LATENCY_WEIGHT threshold=$FRAUD_THRESHOLD"
echo ""

# collect results: score\ticon\tnode\tip\trisk\tdelay\tfinal
RESULTS=""
INDEX=0
while IFS= read -r node; do
  INDEX=$((INDEX + 1))

  printf "[%d/%d] Testing: %s ... " "$INDEX" "$NODE_COUNT" "$node"

  NODE_ENCODED=$(urlencode "$node")
  RESP=$(curl -s --max-time $((REQ_TIMEOUT + 2)) "${CHECK_URL}?node=${NODE_ENCODED}&timeout=${REQ_TIMEOUT}" 2>/tmp/fraud-check-curl.log || echo "")

  if [[ -z "$RESP" ]] && [[ -f /tmp/fraud-check-curl.log ]]; then
    ERR=$(cat /tmp/fraud-check-curl.log)
    if [[ -n "$ERR" ]]; then
      printf "ERROR: %s\n" "$ERR"
      RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tError\t-\t-1\t-\t0\n"
      continue
    fi
  fi

  if [[ -z "$RESP" ]]; then
    printf "TIMEOUT\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t-\tTimeout\t-\t-1\t-\t0\n"
    continue
  fi

  read -r SCORE IP COUNTRY_CODE ELAPSED <<< "$(echo "$RESP" | jq -r '[.fraudScore // "", .ip // "", .countryCode // "", .elapsed // 0] | @tsv' 2>/dev/null)"
  ELAPSED="${ELAPSED:-0}"

  # get delay from cached data first, fallback to real-time test
  NODE_DELAY=$(echo "$NODE_MAP" | grep -m1 -F "$(printf '%s\t' "$node")" | cut -f3)
  NODE_DELAY="${NODE_DELAY:-0}"
  if [[ -z "$NODE_DELAY" || "$NODE_DELAY" == "0" ]]; then
    NODE_DELAY=$(api_get "/proxies/$NODE_ENCODED/delay?timeout=5000&url=http://cp.cloudflare.com/generate_204" | jq -r '.delay // empty' 2>/dev/null)
  fi

  if [[ -z "$SCORE" ]]; then
    printf "NO DATA\n"
    RESULTS="${RESULTS}-1\t⚪\t${node}\t${IP:-?}\tNo Data\t${NODE_DELAY:--}\t-1\t-\t0\n"
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

  # calculate final score (3-factor: fraud score + proxy delay + ippure latency)
  FINAL="-1"
  if ([[ -n "$NODE_DELAY" && "$NODE_DELAY" != "0" ]] || [[ "$ELAPSED" != "0" && -n "$ELAPSED" ]]) && (( SCORE < FRAUD_THRESHOLD )); then
    BC_EXPR="scale=4; s=$FRAUD_WEIGHT*l((100-$SCORE)/100)"
    if [[ -n "$NODE_DELAY" && "$NODE_DELAY" != "0" ]]; then
      BC_EXPR="$BC_EXPR - $DELAY_WEIGHT*$NODE_DELAY/500"
    fi
    if [[ "$ELAPSED" != "0" && -n "$ELAPSED" ]]; then
      BC_EXPR="$BC_EXPR - $LATENCY_WEIGHT*$ELAPSED/2000"
    fi
    FINAL=$(echo "$BC_EXPR; e(s)" | bc -l)
  fi

  DELAY_STR="${NODE_DELAY:--}ms"
  ELAPSED_STR="${ELAPSED:-0}ms"
  printf "%s %s (Score: %d, %s, %s, Latency: %s, Final: %s)\n" "$ICON" "$IP" "$SCORE" "$RISK" "$DELAY_STR" "$ELAPSED_STR" "$FINAL"
  RESULTS="${RESULTS}${SCORE}\t${ICON}\t${node}\t${IP}\t${RISK}\t${NODE_DELAY:--}\t${FINAL}\t${COUNTRY_CODE:--}\t${ELAPSED:-0}\n"

done <<< "$NODES"

# print sorted summary
echo ""
echo "============================================ Summary ============================================="
printf "    %-38s %-16s %5s  %-6s %7s  %7s  %6s\n" "Node" "IP" "Score" "Risk" "Delay" "Latency" "Final"
echo "──────────────────────────────────────────────────────────────────────────────────────────────────"

BEST_NODE=""
BEST_FINAL="-1"

SORTED=$(printf '%b' "$RESULTS" | sort -t$'\t' -k7 -g -r)
echo "$SORTED" | while IFS=$'\t' read -r score icon node ip risk delay final cc elapsed; do
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
  if [[ -z "$elapsed" || "$elapsed" == "0" ]]; then
    elapsed_str="   -"
  else
    elapsed_str="${elapsed}ms"
  fi
  if [[ "$cc" != "-" && -n "$cc" ]]; then
    display_node="[$cc]$node"
  else
    display_node="$node"
  fi
  node_padded=$(pad_right "$icon $display_node" 42)
  printf '%s %-16s %5s  %-6s %7s  %7s  %6s\n' "$node_padded" "$ip" "$score" "$risk" "$delay_str" "$elapsed_str" "$final_str"
done

# find best node (outside subshell)
BEST_LINE=$(echo "$SORTED" | head -1)
BEST_FINAL=$(echo "$BEST_LINE" | cut -d$'\t' -f7)
BEST_NODE=$(echo "$BEST_LINE" | cut -d$'\t' -f3)

echo "──────────────────────────────────────────────────────────────────────────────────────────────────"

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
  SELECT_DATA=$(echo "$ALL_PROXIES" | jq --arg g "$SELECT_GROUP" '.proxies[$g]')
  SELECT_TYPE=$(echo "$SELECT_DATA" | jq -r '.type')

  if [[ "$SELECT_TYPE" != "Selector" && "$SELECT_TYPE" != "select" ]]; then
    echo "Error: Group '$SELECT_GROUP' is type '$SELECT_TYPE', not select. Cannot auto-switch."
    exit 1
  fi

  # resolve the correct direct member to select
  SELECT_TARGET="$BEST_NODE"
  TOP_MEMBER=$(lookup_top_member "$BEST_NODE")
  if [[ -n "$TOP_MEMBER" && "$TOP_MEMBER" != "$BEST_NODE" ]]; then
    SELECT_TARGET="$TOP_MEMBER"
    echo "Best node '$BEST_NODE' belongs to sub-group '$TOP_MEMBER'"
  fi

  echo "Switching '$SELECT_GROUP' → $SELECT_TARGET ..."
  SELECT_ENCODED=$(urlencode "$SELECT_GROUP")
  PUT_RESP=$(api_put "/proxies/$SELECT_ENCODED" "{\"name\":\"$SELECT_TARGET\"}")

  # PUT returns empty body on 204 success
  if [[ -z "$PUT_RESP" ]]; then
    echo "Switched successfully."
  else
    echo "Switch response: $PUT_RESP"
  fi
fi
