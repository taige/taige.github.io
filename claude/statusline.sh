#!/bin/bash
input=$(cat)

# Colors
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
ORANGE='\033[38;5;208m'
DIM='\033[2m'
RESET='\033[0m'

# Parse JSON
MODEL=$(echo "$input" | jq -r '.model.display_name // "?"')
DIR=$(echo "$input" | jq -r '.workspace.current_dir // "."')
DIR_NAME="${DIR##*/}"
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')

# Format token counts
fmt_tokens() {
    local n=$1
    if [ "$n" -lt 1000 ]; then
        echo "$n"
    else
        echo "$(( (n + 500) / 1000 ))k"
    fi
}

SEND_FMT=$(fmt_tokens "$INPUT_TOKENS")
RECV_FMT=$(fmt_tokens "$OUTPUT_TOKENS")

# Context used/total
USED=$(( PCT * CTX_SIZE / 100 ))
USED_FMT=$(fmt_tokens "$USED")
CTX_FMT=$(fmt_tokens "$CTX_SIZE")

# Progress bar (20 chars)
BAR_WIDTH=20
FILLED=$((PCT * BAR_WIDTH / 100))
EMPTY=$((BAR_WIDTH - FILLED))

if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 75 ]; then BAR_COLOR="$ORANGE"
elif [ "$PCT" -ge 50 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILL_STR=""; EMPTY_STR=""
[ "$FILLED" -gt 0 ] && FILL_STR=$(printf "%${FILLED}s" | tr ' ' '█')
[ "$EMPTY" -gt 0 ] && EMPTY_STR=$(printf "%${EMPTY}s" | tr ' ' '░')
BAR="${BAR_COLOR}${FILL_STR}${DIM}${EMPTY_STR}${RESET}"

# Duration
DURATION_SEC=$((DURATION_MS / 1000))
if [ "$DURATION_SEC" -ge 3600 ]; then
    HOURS=$((DURATION_SEC / 3600))
    MINS=$(( (DURATION_SEC % 3600) / 60 ))
    DURATION_FMT="${HOURS}h ${MINS}m"
else
    MINS=$((DURATION_SEC / 60))
    SECS=$((DURATION_SEC % 60))
    DURATION_FMT="${MINS}m ${SECS}s"
fi

# Cost
COST_FMT=$(printf '$%.2f' "$COST")

# Git branch & diff stats
BRANCH=""
FILE_COUNT=0
DIFF_ADD=0
DIFF_DEL=0
if git rev-parse --git-dir > /dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null)
    SHORTSTAT=$(git diff --shortstat HEAD 2>/dev/null)
    FILE_COUNT=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+')
    DIFF_ADD=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')
    DIFF_DEL=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')
    FILE_COUNT=${FILE_COUNT:-0}
    DIFF_ADD=${DIFF_ADD:-0}
    DIFF_DEL=${DIFF_DEL:-0}
fi

# Build two lines
LINE1="${CYAN}[${MODEL}]${RESET} 📁 ${DIR_NAME}"
[ -n "$BRANCH" ] && LINE1="${LINE1} ${DIM}|${RESET} 🔀 ${GREEN}${BRANCH}${RESET}"
LINE1="${LINE1} ${DIM}|${RESET} ${FILE_COUNT} files ${GREEN}+${DIFF_ADD}${RESET} ${RED}-${DIFF_DEL}${RESET}"

LINE2="${BAR} ${BAR_COLOR}${PCT}%${RESET} ${DIM}(${USED_FMT}/${CTX_FMT})${RESET}"
LINE2="${LINE2} ${DIM}|${RESET} ${DIM}↑${SEND_FMT} ↓${RECV_FMT}${RESET}"
LINE2="${LINE2} ${DIM}|${RESET} ${YELLOW}${COST_FMT}${RESET}"
LINE2="${LINE2} ${DIM}|${RESET} ${DIM}⏱ ${DURATION_FMT}${RESET}"

echo -e "${LINE1}\n${LINE2}"
