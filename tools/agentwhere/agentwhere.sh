#!/usr/bin/env bash
# agentwhere -- decide from evidence where a Claude Code subagent actually ran.
#
# WHY
# The Agent tool takes `isolation: "remote"`, and when remote execution is not
# available for the session it falls back to a local git worktree.  The launch
# result is identical either way: "Async agent launched successfully", an agent
# id, and an output path.  Nothing in it names the isolation mode that was
# actually granted, so asking for remote and believing you got it is a mistake
# with no feedback attached to it.  On 2026-09-13 three agents were launched
# with isolation: "remote", ran on this machine, and were reported as cloud
# work for four turns before the user noticed local scratch directories.
#
# The evidence was there the whole time.  This collects it.
#
# EVIDENCE, in descending order of how much it settles
#   1. a git worktree named .claude/worktrees/agent-<id>   -- conclusive LOCAL
#   2. a live local process holding that worktree open      -- conclusive LOCAL, still running
#   3. scratch under a local /tmp that the agent reported   -- strong LOCAL
#   4. a task output file but none of the above             -- NOT LOCAL, likely remote
# Absence of 1-3 is not proof of remote, only absence of local evidence, so
# that case prints NO-LOCAL-EVIDENCE rather than REMOTE.  The point of this
# script is to stop a claim being made from an intention; it will not invent a
# positive claim of its own.
#
# usage
#   tools/agentwhere/agentwhere.sh                 report on every agent worktree
#   tools/agentwhere/agentwhere.sh <agent-id>...   report on these ids
#   tools/agentwhere/agentwhere.sh --load          add CPU contention (see below)
#
# CONTENTION.  A local agent is not free: it competes with whatever else you
# are running.  --load prints the run queue against the core count, because
# "parallelise the simulation across 16 cores" and "spawn three agents that
# each want cores" are the same budget, and the second silently eats the first.
set -u

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not in a git repo"; exit 1; }
WANT_LOAD=0
IDS=()
for a in "$@"; do
    case "$a" in
        --load) WANT_LOAD=1 ;;
        -*)     echo "unknown option: $a" >&2; exit 2 ;;
        *)      IDS+=("$a") ;;
    esac
done

# The worktree list is the primary record: one line per checkout, and an agent
# that was given a local worktree appears here by construction.
mapfile -t WT < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')

wt_for() {   # agent id -> its worktree path, empty if none
    local id=$1 w
    for w in "${WT[@]}"; do
        [[ "$w" == *"/.claude/worktrees/agent-$id" ]] && { echo "$w"; return; }
    done
}

if [ ${#IDS[@]} -eq 0 ]; then
    for w in "${WT[@]}"; do
        [[ "$w" == *"/.claude/worktrees/agent-"* ]] && IDS+=("${w##*/agent-}")
    done
fi

if [ ${#IDS[@]} -eq 0 ]; then
    echo "no agent worktrees under $REPO/.claude/worktrees/"
    echo "  -> no local evidence for any agent in this repo."
    echo "     That is not proof they ran remotely; pass ids explicitly to check them."
else
    printf '%-20s %-22s %s\n' AGENT VERDICT EVIDENCE
    for id in "${IDS[@]}"; do
        w=$(wt_for "$id")
        if [ -n "$w" ]; then
            ev="worktree ${w#$REPO/}"
            #  A locked worktree is one the harness is still holding, i.e. the
            #  agent has not been reaped.  Cheap liveness signal that needs no
            #  process table walk and no guessing at process names.
            [ -f "$w/../../worktrees/agent-$id/.git" ] 2>/dev/null
            if git worktree list | grep -q "agent-$id.*locked"; then
                ev="$ev (locked: still held)"
            fi
            age=$(( ( $(date +%s) - $(stat -c %Y "$w" 2>/dev/null || echo 0) ) / 60 ))
            printf '%-20s %-22s %s, touched %sm ago\n' "$id" LOCAL "$ev" "$age"
        else
            printf '%-20s %-22s %s\n' "$id" NO-LOCAL-EVIDENCE "no worktree; check /tmp and ListAgents before claiming remote"
        fi
    done
fi

#  Scratch directories an agent mentions in its report are the other half of
#  the story: if the path it names exists on this machine, it ran here.  We
#  cannot know which paths it named, so list the plausible recent ones and let
#  the caller match them against the report.
echo
echo "recent local /tmp scratch (match these against what an agent reported):"
find /tmp -maxdepth 1 -type d -newermt '-6 hours' \
     ! -name 'tmp' ! -name '.*' ! -name 'systemd-*' ! -name 'claude-*' \
     -printf '  %f\n' 2>/dev/null | head -20 || echo "  (none)"

if [ "$WANT_LOAD" = 1 ]; then
    echo
    cores=$(nproc)
    read -r l1 _ < /proc/loadavg
    echo "contention: load ${l1} on ${cores} cores"
    awk -v l="$l1" -v c="$cores" 'BEGIN{
        if (l > c*0.95) print "  saturated -- local agents and local simulations are taking cycles from each other"
        else printf "  %.0f%% committed\n", 100*l/c }'
fi
