#!/usr/bin/env bash
#
# claude-airlock statusline. Mirrors the host statusline, but drops user@host
# (inside the box it's just "dev@airlock") and leads with a bold (airlock) badge
# so it's always obvious the session is sandboxed/firewalled. Shows the project
# folder, git branch, model, context %, and subscription rate limits.
input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
project=$(basename "$cwd")
model=$(echo "$input" | jq -r '.model.display_name' | sed 's/ *([^)]*)//')
ctx=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
rate_5h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
rate_7d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

branch=""
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
             || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
fi

# (airlock) badge — bold dark green, so "you're in the sandbox" is unmistakable
printf "\033[1;38;5;28m(airlock)\033[0m"

# dim separator so the badge doesn't blur into the folder name
printf " \033[90m-\033[0m"

# project folder — blue (matches the host statusline's cwd color)
printf " \033[34m%s\033[0m" "$project"

# git branch — yellow
[ -n "$branch" ] && printf " \033[33m(%s)\033[0m" "$branch"

# model — cyan
printf " \033[36m%s\033[0m" "$model"

# context % — magenta
[ -n "$ctx" ] && printf " \033[35mctx:%.0f%%\033[0m" "$ctx"

# subscription rate limits — slate blue, after a magenta separator
if [ -n "$ctx" ] && { [ -n "$rate_5h" ] || [ -n "$rate_7d" ]; }; then
    printf " \033[35m|\033[0m"
fi
if [ -n "$rate_5h" ] && [ -n "$rate_7d" ]; then
    printf " \033[38;5;99m5h:%.0f%% wk:%.0f%%\033[0m" "$rate_5h" "$rate_7d"
elif [ -n "$rate_5h" ]; then
    printf " \033[38;5;99m5h:%.0f%%\033[0m" "$rate_5h"
elif [ -n "$rate_7d" ]; then
    printf " \033[38;5;99mwk:%.0f%%\033[0m" "$rate_7d"
fi
