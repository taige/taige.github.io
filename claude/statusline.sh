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
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | xargs printf '%.0f')
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
INPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
OUTPUT_TOKENS=$(echo "$input" | jq -r '.context_window.total_output_tokens // 0')
FIVE_H_PCT=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_D_PCT=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
SEVEN_D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

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

# Progress bar generator: make_bar <pct> <width>
make_bar() {
    local pct=$1 width=$2
    local filled=$((pct * width / 100))
    local empty=$((width - filled))
    local color
    if [ "$pct" -ge 90 ]; then color="$RED"
    elif [ "$pct" -ge 75 ]; then color="$ORANGE"
    elif [ "$pct" -ge 50 ]; then color="$YELLOW"
    else color="$GREEN"; fi
    local fill_str="" empty_str=""
    [ "$filled" -gt 0 ] && fill_str=$(printf "%${filled}s" | tr ' ' '█')
    [ "$empty" -gt 0 ] && empty_str=$(printf "%${empty}s" | tr ' ' '░')
    echo "${color}${fill_str}${DIM}${empty_str}${RESET}"
}

# Bar color for percentage
bar_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$RED"
    elif [ "$pct" -ge 75 ]; then echo "$ORANGE"
    elif [ "$pct" -ge 50 ]; then echo "$YELLOW"
    else echo "$GREEN"; fi
}

# Rate limit bar with time marker: make_rate_bar <usage_pct> <time_pct> <width>
# Shows usage fill + │ marker at time position to visualize pace
make_rate_bar() {
    local usage_pct=$1 time_pct=$2 width=$3
    local usage_pos=$((usage_pct * width / 100))
    local time_pos=$((time_pct * width / 100))
    # Clamp time_pos
    [ "$time_pos" -lt 0 ] && time_pos=0
    [ "$time_pos" -ge "$width" ] && time_pos=$((width - 1))
    # Color based on usage vs time (cap at yellow when usage < 50%)
    local color
    if [ "$usage_pct" -ge 90 ]; then color="$RED"
    elif [ "$time_pct" -le 0 ] || [ "$usage_pct" -le "$time_pct" ]; then color="$GREEN"
    elif [ "$usage_pct" -lt 50 ] || [ "$usage_pct" -le $((time_pct * 3 / 2)) ]; then color="$YELLOW"
    else color="$ORANGE"; fi
    # Build bar char by char
    local bar="" i
    for ((i=0; i<width; i++)); do
        if [ "$i" -eq "$time_pos" ]; then
            bar="${bar}${RESET}${DIM}│${RESET}${color}"
        elif [ "$i" -lt "$usage_pos" ]; then
            bar="${bar}█"
        else
            bar="${bar}░"
        fi
    done
    echo "${color}${bar}${RESET}"
}

# Rate limit bar color based on usage vs time
rate_bar_color() {
    local usage_pct=$1 time_pct=$2
    if [ "$usage_pct" -ge 90 ]; then echo "$RED"
    elif [ "$time_pct" -le 0 ] || [ "$usage_pct" -le "$time_pct" ]; then echo "$GREEN"
    elif [ "$usage_pct" -lt 50 ] || [ "$usage_pct" -le $((time_pct * 3 / 2)) ]; then echo "$YELLOW"
    else echo "$ORANGE"; fi
}

# Format remaining time from epoch: fmt_remaining <epoch>
fmt_remaining() {
    local epoch=$1
    [ -z "$epoch" ] && return
    local now remaining
    now=$(date +%s)
    remaining=$((epoch - now))
    [ "$remaining" -le 0 ] && echo "0m" && return
    local days=$((remaining / 86400))
    if [ "$days" -ge 1 ]; then
        local hours=$(( (remaining % 86400) / 3600 ))
        echo "${days}d${hours}h"
    else
        local hours=$((remaining / 3600))
        local mins=$(( (remaining % 3600) / 60 ))
        if [ "$hours" -gt 0 ]; then
            echo "${hours}h${mins}m"
        else
            echo "${mins}m"
        fi
    fi
}

# Context window bar
BAR=$(make_bar "$PCT" 20)
BAR_COLOR=$(bar_color "$PCT")

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

# Rate limits
NOW=$(date +%s)

if [ -n "$FIVE_H_PCT" ]; then
    FIVE_H_PCT_INT=$(printf '%.0f' "$FIVE_H_PCT")
    FIVE_H_REMAINING=$(fmt_remaining "$FIVE_H_RESET")
    if [ -n "$FIVE_H_RESET" ]; then
        FIVE_H_TIME_PCT=$(( (18000 - (FIVE_H_RESET - NOW)) * 100 / 18000 ))
        [ "$FIVE_H_TIME_PCT" -lt 0 ] && FIVE_H_TIME_PCT=0
        [ "$FIVE_H_TIME_PCT" -gt 100 ] && FIVE_H_TIME_PCT=100
        FIVE_H_BAR=$(make_rate_bar "$FIVE_H_PCT_INT" "$FIVE_H_TIME_PCT" 10)
        FIVE_H_COLOR=$(rate_bar_color "$FIVE_H_PCT_INT" "$FIVE_H_TIME_PCT")
    else
        FIVE_H_BAR=$(make_bar "$FIVE_H_PCT_INT" 10)
        FIVE_H_COLOR=$(bar_color "$FIVE_H_PCT_INT")
    fi
    FIVE_H_FMT="5h ${FIVE_H_BAR} ${FIVE_H_COLOR}${FIVE_H_PCT_INT}%${RESET}"
    [ -n "$FIVE_H_REMAINING" ] && FIVE_H_FMT="${FIVE_H_FMT} ${DIM}(${FIVE_H_REMAINING})${RESET}"
else
    FIVE_H_FMT="${DIM}5h --${RESET}"
fi

if [ -n "$SEVEN_D_PCT" ]; then
    SEVEN_D_PCT_INT=$(printf '%.0f' "$SEVEN_D_PCT")
    SEVEN_D_REMAINING=$(fmt_remaining "$SEVEN_D_RESET")
    if [ -n "$SEVEN_D_RESET" ]; then
        SEVEN_D_TIME_PCT=$(( (604800 - (SEVEN_D_RESET - NOW)) * 100 / 604800 ))
        [ "$SEVEN_D_TIME_PCT" -lt 0 ] && SEVEN_D_TIME_PCT=0
        [ "$SEVEN_D_TIME_PCT" -gt 100 ] && SEVEN_D_TIME_PCT=100
        SEVEN_D_BAR=$(make_rate_bar "$SEVEN_D_PCT_INT" "$SEVEN_D_TIME_PCT" 14)
        SEVEN_D_COLOR=$(rate_bar_color "$SEVEN_D_PCT_INT" "$SEVEN_D_TIME_PCT")
    else
        SEVEN_D_BAR=$(make_bar "$SEVEN_D_PCT_INT" 14)
        SEVEN_D_COLOR=$(bar_color "$SEVEN_D_PCT_INT")
    fi
    SEVEN_D_FMT="7d ${SEVEN_D_BAR} ${SEVEN_D_COLOR}${SEVEN_D_PCT_INT}%${RESET}"
    [ -n "$SEVEN_D_REMAINING" ] && SEVEN_D_FMT="${SEVEN_D_FMT} ${DIM}(${SEVEN_D_REMAINING})${RESET}"
else
    SEVEN_D_FMT="${DIM}7d --${RESET}"
fi

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
LINE2="${LINE2} ${DIM}|${RESET} ${FIVE_H_FMT}"
LINE2="${LINE2} ${DIM}|${RESET} ${SEVEN_D_FMT}"
LINE2="${LINE2} ${DIM}|${RESET} ${DIM}↑${SEND_FMT} ↓${RECV_FMT}${RESET}"
LINE2="${LINE2} ${DIM}|${RESET} ${YELLOW}${COST_FMT}${RESET}"
# Uncomment to show duration:
# LINE2="${LINE2} ${DIM}|${RESET} ${DIM}⏱ ${DURATION_FMT}${RESET}"

echo -e "${LINE1}\n${LINE2}"