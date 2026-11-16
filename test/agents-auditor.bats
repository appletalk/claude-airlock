#!/usr/bin/env bats
# The auditor (an auditor line in agents.conf): the site file's rules for it, the operator's
# `audit` runs (lib/audit-run in the auditor's manager, the report the operator command writes)
# and what audit-run hands the launcher. machinectl, systemd-run, the launcher and curl are stubs:
# the run is a stub airlock that prints a report, the store a stub curl answering from fixtures.
# Nothing real is touched.

setup() {
    unset AIRLOCK_AGENTS_ROOT AIRLOCK_AGENTS_SYSTEMD_VERSION
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    A="$REPO/agents/airlock-agents-apply"
    OP="$REPO/agents/operator"
    ME="$(id -un)"
    mkdir -p "$T/bin" "$T/nd" "$T/run" "$T/reports" "$T/home" "$T/stats" "$T/share/box"
    export AIRLOCK_AGENTS_ENV="$T/agents.env" HOME="$T/home" XDG_RUNTIME_DIR="$T/run" TZ=UTC \
        AGENTS_AUDIT_SOCK="$T/vl.sock" CALLS="$T/calls" STATS="$T/stats" AGENTS_NODUMP_DIR="$T/nd"
    # the auditor is this test's own user (audit-run checks it runs as the auditor)
    printf '%s\n' AGENTS_OPERATOR=alice AGENTS_COMMAND=agent AGENTS_AGENT=agent AGENTS_AGENT_UID=1100 \
        "AGENTS_INBOX=$T/inbox" AGENTS_WEB=agent-web AGENTS_WEB_UID=1101 AGENTS_GUARD=agent-guard AGENTS_GUARD_UID=1102 \
        "AGENTS_QUEUE=$T/q" AGENTS_AUDIT=on "AGENTS_AUDITOR=$ME" "AGENTS_AUDITOR_UID=$(id -u)" \
        "AGENTS_AUDIT_REPORTS=$T/reports" "AGENTS_LIB=$REPO/agents/lib" "AGENTS_SHARE=$T/share" > "$AIRLOCK_AGENTS_ENV"
    cp "$REPO/agents/box/auditor-prompt.md" "$T/share/box/"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$AGENTS_AUDIT_SOCK"
    # the auditor's claude-airlock config and its listener's client manifest
    export AIRLOCK_CONFIG="$T/auditor.conf"
    printf 'AIRLOCK_EGRESS_PROXY=%s\n' "$T/run/aud-store.sock" > "$AIRLOCK_CONFIG"
    printf '# manifest\naudit.internal 443 victoria-logs no\n' > "$T/run/aud-store.clients"
    # machinectl: orun's remote shell run for real (systemd-run a stub that runs what follows --)
    cat > "$T/bin/machinectl" <<'S'
#!/bin/bash
echo "machinectl $*" >> "$CALLS.machinectl"
if [[ "$4" == */sh && "$5" == -c ]]; then exec "$4" -c "$6" "${@:7}"; fi
exit 0
S
    printf '#!/bin/bash\nwhile [ "$1" != -- ]; do shift; done; shift\nexec "$@"\n' > "$T/bin/systemd-run"
    ln -sf /bin/bash "$T/nd/sh"; ln -sf "$T/bin/systemd-run" "$T/nd/systemd-run"; ln -sf /bin/true "$T/nd/systemctl"
    for b in sh systemd-run systemctl; do echo 0:0:711 > "$STATS/$(printf '%s' "$T/nd/$b" | tr / _)"; done
    cat > "$T/bin/stat" <<'S'
#!/bin/bash
f="$STATS/$(printf '%s' "${*: -1}" | tr / _)"
if [ "$1 $2" = "-c %u:%g:%a" ] && [ -f "$f" ]; then cat "$f"; else exec /usr/bin/stat "$@"; fi
S
    # the launcher: its arguments one per line, then the report (REPORT, else a fixed one), RC
    export AGENTS_AUDIT_AIRLOCK="$T/bin/airlock"
    cat > "$T/bin/airlock" <<'S'
#!/bin/bash
{ echo "cwd=$PWD"; printf '%s\n' "$@"; } > "$CALLS.airlock"
ls -A "$PWD" > "$CALLS.ws"
printf '%b' "${REPORT:-**Summary**: nothing needs you.\n}"
exit "${RC:-0}"
S
    # curl, the store: a count after the run answers CAUGHT (default 1); the run's Envoy lines
    # answer $T/rows; every query is logged
    cat > "$T/bin/curl" <<'S'
#!/bin/bash
q=""; for a; do case "$a" in query=*) q=${a#query=} ;; esac; done
printf '%s\n' "$q" >> "$CALLS"
case "$q" in
    *'stats count() n'*) echo "{\"n\":\"${CAUGHT:-1}\"}" ;;
    *) cat "$(dirname "$CALLS")/rows" ;;
esac
printf '\n200'
S
    # podman: the auditor's running containers (RUNNING)
    printf '#!/bin/bash\n[ "$1" = ps ] && printf "%%s" "${RUNNING:-}"\nexit 0\n' > "$T/bin/podman"
    export AIRLOCK_TMP_BASE="$T/airlock-tmp" AGENTS_AUDIT_PODMAN="$T/bin/podman"
    chmod +x "$T/bin/"*
    export PATH="$T/bin:$PATH"
    : > "$T/rows"; : > "$CALLS"
}
row() { printf '%s\n' "$1" >> "$T/rows"; }
report_file() { find "$T/reports" -name '*.md' | head -1; }

# ---- the site file -------------------------------------------------------------------------------

@test "site: an auditor needs audit on; with it, its names, reports dir and config" {
    mkdir -p "$T/sbin"; printf '#!/bin/sh\n[ "$1" = passwd ] && [ -n "$2" ] && echo "$2:x:1000:1000::/home/$2:/bin/sh"\n' > "$T/sbin/getent"
    printf '#!/bin/sh\necho "systemd 258 (258.1)"\n' > "$T/sbin/systemctl"; chmod +x "$T/sbin/"*
    base='operator alice\nagent claude uid 1100 subuid 1100000 home 30G\nauditor claude-audit uid 1103 subuid 1400000 home 10G\n'
    printf '%b' "$base" > "$T/site"
    PATH="$T/sbin:$PATH" run "$A" --env "$T/site"
    [ "$status" -ne 0 ]; [[ "$output" == *"an auditor line needs audit on"* ]]
    printf '%baudit on\n' "$base" > "$T/site"
    PATH="$T/sbin:$PATH" run "$A" --env "$T/site"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qx AGENTS_AUDITOR=claude-audit <<< "$output"
    grep -qx AGENTS_AUDITOR_UID=1103 <<< "$output"
    grep -qx AGENTS_AUDIT_REPORTS=/srv/claude-audit/reports <<< "$output"
    PATH="$T/sbin:$PATH" run "$A" --user-conf claude-audit "$T/site"
    grep -qx 'AIRLOCK_IMAGE=claude-airlock:base' <<< "$output"
    grep -qx 'AIRLOCK_EGRESS_PROXY=/run/airlock-envoy/claude-audit/claude-audit-store.sock' <<< "$output"
    grep -qx 'AIRLOCK_MANAGED_SETTINGS=/usr/local/share/airlock-agents/managed-settings-auditor.json' <<< "$output"
    grep -qx 'AIRLOCK_SHARE_MEMORY=off' <<< "$output"
    PATH="$T/sbin:$PATH" run "$A" --render "$T/r" "$T/site"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -qE '^d /srv/claude-audit +0755 root root -$' "$T/r/etc/tmpfiles.d/airlock-agents-reports.conf"
    grep -qE '^d /srv/claude-audit/reports +0700 alice alice -$' "$T/r/etc/tmpfiles.d/airlock-agents-reports.conf"
    # an agent user like the others: its own manager sandbox, slice, home, nft drop, polkit entry,
    # and the store reads its lines
    [ -f "$T/r/etc/systemd/system/user@1103.service.d/10-airlock-agents.conf" ]
    grep -qx 'PrivateNetwork=yes' "$T/r/etc/systemd/system/user@1103.service.d/10-airlock-agents.conf"
    grep -qx 'ReadWritePaths=/home/claude-audit /run/user/1103' "$T/r/etc/systemd/system/user@1103.service.d/10-airlock-agents.conf"
    grep -qx 'MemoryMax=3G' "$T/r/etc/systemd/system/user-1103.slice.d/10-airlock-agents.conf"
    [ -f "$T/r/etc/systemd/system/home-claude\\x2daudit.mount" ]
    grep -q 'meta skuid { 1103, 1400000-1465535 } counter drop' "$T/r/etc/airlock-agents.nft"
    grep -q '"claude-audit"' "$T/r/etc/polkit-1/rules.d/50-airlock-agents.rules"
    grep -q '_UID=1103' "$T/r/etc/systemd/system/airlock-audit-journal.service"
}

@test "site: the inbox or the queue can't be the auditor's /srv dir" {
    printf 'operator alice\naudit on\nagent claude uid 1100 subuid 1100000 home 30G\ninbox /srv/aud\nauditor aud uid 1103 subuid 1400000 home 10G\n' > "$T/site"
    run "$A" --env "$T/site"
    [ "$status" -ne 0 ]; [[ "$output" == *"/srv/aud is the auditor's"* ]]
}

@test "the auditor's managed settings: no messages, agents, web tools or file writes; Bash stays (curl to the store)" {
    s="$REPO/agents/share/managed-settings-auditor.json"
    for d in SendMessage ListAgents Agent WebFetch WebSearch Write Edit NotebookEdit RemoteTrigger CronCreate; do
        jq -e --arg d "$d" '.permissions.deny | index($d)' "$s" >/dev/null || { echo "no deny for $d"; return 1; }
    done
    jq -e '.permissions.deny | index("Bash") | not' "$s" >/dev/null
    jq -e '.disableRemoteControl == true and .crossSessionInbound == "refuse" and .allowManagedHooksOnly == true and .allowManagedPermissionRulesOnly == true' "$s" >/dev/null
    # no tool that writes files beyond curl (sort -o, uniq OUT)
    ! jq -e '.permissions.allow | map(select(test("^Bash[(](sort|uniq|tee|sed|awk|python|bash|sh|dd|cp|mv)[:)]"))) | length > 0' "$s" >/dev/null
}

# ---- audit-run -----------------------------------------------------------------------------------

@test "audit-run: a fresh one-shot run: empty workspace and memory, Bash for curl and text tools only, capped" {
    mkdir -p "$T/home/audit/.claude" "$T/home/.config/claude-airlock/state/$(printf '%s' "$T/home/audit" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')/box-memory"
    echo planted > "$T/home/audit/CLAUDE.md"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -s "$CALLS.ws" ] || { echo "workspace not empty: $(cat "$CALLS.ws")"; return 1; }
    [ ! -d "$T/home/.config/claude-airlock/state/$(printf '%s' "$T/home/audit" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')/box-memory" ]
    a="$CALLS.airlock"
    grep -qx "cwd=$T/home/audit" "$a"
    for want in -p --restricted --strict-mcp-config --tools Bash --permission-mode dontAsk --max-turns 60 --output-format text --append-system-prompt; do
        grep -qxF -- "$want" "$a" || { echo "lacks $want"; cat "$a"; return 1; }
    done
    [ "$(sed -n '/^--allowedTools$/{n;p;}' "$a")" = "Bash(curl:*),Bash(jq:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(cut:*),Bash(grep:*),Bash(date:*)" ]
    # the same list is the managed settings' allow list, which alone counts there
    [ "$(jq -r '.permissions.allow | join(",")' "$REPO/agents/share/managed-settings-auditor.json")" = "$(sed -n '/^--allowedTools$/{n;p;}' "$a")" ]
    [[ "$(sed -n '/^-p$/{n;p;}' "$a")" == "Review the last 7 days in the audit store (from "* ]]
    # the instructions with the site's names and the store's host from the manifest
    grep -qF "curl -sS -G 'http://audit.internal/select/logsql/query'" "$a"
    grep -qF "The agents (agent, agent-web, agent-guard, $ME)" "$a"
    ! grep -qE '\{(auditor|agents|operator|command|store)\}' "$a"
    [[ "$output" == *"nothing needs you."* ]]
}

@test "audit-run: a question goes in as the operator's words; bad input and a missing store are refused (64)" {
    run "$REPO/agents/lib/audit-run" ask "what did agent do at noon?"
    [ "$status" -eq 0 ]
    p="$(sed -n '/^-p$/,/^--name$/p' "$CALLS.airlock")"
    [[ "$p" == *"The question (the operator's own words):"*"what did agent do at noon?"* ]] || { echo "$p"; return 1; }
    run "$REPO/agents/lib/audit-run" review 0;   [ "$status" -eq 64 ]
    run "$REPO/agents/lib/audit-run" review 91;  [ "$status" -eq 64 ]
    run "$REPO/agents/lib/audit-run" ask "";     [ "$status" -eq 64 ]
    run "$REPO/agents/lib/audit-run" ask "$(printf 'a\033[31mb')"; [ "$status" -eq 64 ]; [[ "$output" == *"control characters"* ]]
    run "$REPO/agents/lib/audit-run" ask a b;    [ "$status" -eq 64 ]
    printf '# manifest\napi.example.org 443 github-api yes\n' > "$T/run/aud-store.clients"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 64 ]; [[ "$output" == *"has no audit store"* ]]
    sed -i "s/^AGENTS_AUDITOR=.*/AGENTS_AUDITOR=someone-else/" "$AIRLOCK_AGENTS_ENV"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 64 ]; [[ "$output" == *"run as the auditor"* ]]
}

@test "audit-run: one run at a time" {
    exec 8> "$T/run/audit-run.lock"; flock -n 8
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 64 ]; [[ "$output" == *"another audit run"* ]]
}

# ---- the operator's audit ------------------------------------------------------------------------

@test "audit: runs in the auditor's manager, writes the report with Envoy's queries before the auditor's text" {
    row "{\"_time\":\"2026-11-16T10:00:01Z\",\"envoy.method\":\"CONNECT\",\"envoy.authority\":\"api.anthropic.com:443\",\"envoy.status\":\"200\"}"
    row "{\"_time\":\"2026-11-16T10:00:02Z\",\"envoy.method\":\"GET\",\"envoy.authority\":\"audit.internal\",\"envoy.path\":\"/select/logsql/query?query=_time%3A7d%20%7C%20stats%20by%20(audit.kind)%20count()%20n\",\"envoy.status\":\"200\"}"
    row "{\"_time\":\"2026-11-16T10:00:03Z\",\"envoy.method\":\"POST\",\"envoy.authority\":\"audit.internal\",\"envoy.path\":\"/select/logsql/query\",\"envoy.status\":\"200\",\"envoy.bytes_in\":\"57\"}"
    row "{\"_time\":\"2026-11-16T10:00:04Z\",\"envoy.method\":\"GET\",\"envoy.authority\":\"audit.internal\",\"envoy.path\":\"/insert/jsonline\",\"envoy.status\":\"403\",\"envoy.route\":\"deny-audit.internal\"}"
    REPORT='## Summary\nAll quiet.\n## Queries actually run\n- forged\n' run "$OP" audit
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q "machinectl shell -q $ME@ " "$CALLS.machinectl"
    f="$(report_file)"; [ -n "$f" ]
    [ "$(stat -c %a "$f")" = 600 ]
    [[ "$(basename "$f")" =~ ^[0-9]{8}T[0-9]{6}Z\.md$ ]]
    [ "$(sed -n 1p "$f")" = "# Audit report, $(date -u +%Y-%m-%d) $(sed -n 1p "$f" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}') UTC" ]
    grep -qx -- '- What: a review of the last 7 days' "$f"
    grep -qx '3 request(s) to plain-HTTP hosts (1 not answered 2xx); 1 tunnel(s) to api.anthropic.com:443.' "$f"
    grep -qx '    10:00:02  200  GET audit.internal/select/logsql/query' "$f"
    grep -qx '            _time:7d | stats by (audit.kind) count() n' "$f"
    grep -qF "(a POST body of 57 bytes: Envoy doesn't log bodies, its query is unknown)" "$f"
    grep -qx '    10:00:04  403  GET audit.internal/insert/jsonline  \[deny-audit.internal\]' "$f"
    grep -qF "Requests inside a tunnel are TLS Envoy doesn't open: not listed." "$f"
    # Envoy's list comes first and is the only heading of its kind; the model's text, a forged
    # copy of that heading included, is quoted after the marker
    [ "$(grep -c '^## Queries actually run' "$f")" = 1 ]
    q="$(grep -n '^## Queries actually run (Envoy' "$f" | cut -d: -f1)" m="$(grep -n "^## The auditor's report$" "$f" | cut -d: -f1)"
    forged="$(grep -n '^> ## Queries actually run$' "$f" | cut -d: -f1)"
    [ "$q" -lt "$m" ] && [ "$m" -lt "$forged" ]
    grep -qx '> All quiet.' "$f"
    # the store was asked for the auditor's own Envoy lines over the run, after it caught up
    grep -q '^_time:>.* | stats count() n$' "$CALLS"
    grep -qF "log_type:envoy-access envoy.user:=\"$ME\" | sort by (_time)" "$CALLS"
    [[ "$output" == *"All quiet."* && "$output" == *"(kept as $f)"* ]]
}

@test "audit: the report is cleaned; a question is shown; --days; a timeout is said" {
    REPORT='\033]52;c;aGk=\007ok \033[31mred\033[0m\n' RC=124 run "$OP" audit "what did agent reach today?"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    f="$(report_file)"
    ! grep -q $'\033' "$f"; ! grep -q $'\007' "$f"
    grep -qx '> ok red' "$f"
    grep -qx -- "- What: the operator's question:" "$f"
    grep -qx '    what did agent reach today?' "$f"
    grep -q 'exit 124 (timed out: the report may be missing or cut)' "$f"
    rm -f "$T/reports/"*
    run "$OP" audit --days 30
    [ "$status" -eq 0 ]
    grep -qx -- '- What: a review of the last 30 days' "$(report_file)"
    [[ "$(sed -n '/^-p$/{n;p;}' "$CALLS.airlock")" == "Review the last 30 days"* ]]
}

@test "audit: the store not caught up or not answering is said, the report still kept" {
    CAUGHT=0 run timeout 60 "$OP" audit
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q "The store had not caught up 30 s after the run: this list may be short" "$(report_file)"
}

@test "audit: refusals: no auditor, halted, a one-word typo, bad --days, audit-run's own refusal writes no report" {
    run "$OP" audit denis
    [ "$status" -ne 0 ]; [[ "$output" == *"unknown audit command 'denis'"* ]]
    run "$OP" audit what did it do
    [ "$status" -ne 0 ]; [[ "$output" == *"a question is one argument"* ]]
    run "$OP" audit --days 0;  [ "$status" -ne 0 ]
    run "$OP" audit --days 91; [ "$status" -ne 0 ]
    run "$OP" audit --bogus;   [ "$status" -ne 0 ]
    printf '# manifest\n' > "$T/run/aud-store.clients"
    run "$OP" audit
    [ "$status" -ne 0 ]; [[ "$output" == *"has no audit store"* && "$output" == *"no run, no report"* ]]
    [ -z "$(report_file)" ]
    mkdir -p "$T/home/.local/state/airlock-agents"; : > "$T/home/.local/state/airlock-agents/halting"
    run "$OP" audit
    [ "$status" -ne 0 ]; [[ "$output" == *"halted"* ]]
    rm "$T/home/.local/state/airlock-agents/halting"
    sed -i "s/^AGENTS_AUDITOR=.*/AGENTS_AUDITOR=/" "$AIRLOCK_AGENTS_ENV"
    run "$OP" audit
    [ "$status" -ne 0 ]; [[ "$output" == *"no auditor here"* ]]
    # denies and events don't need one
    run "$OP" audit denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "audit login: the auditor's box in its workspace" {
    run "$OP" audit login
    grep -q "machinectl shell -q $ME@ $T/nd/systemd-run --user --pty --wait --collect --quiet --same-dir -- /bin/bash -c" "$CALLS.machinectl"
}

@test "audit: Envoy's fields are the agents' text too: control and bidi characters never reach the file; a // path stays whole" {
    row "{\"_time\":\"2026-11-16T10:00:02Z\",\"envoy.method\":\"GET\",\"envoy.authority\":\"audit.internal\\u001b[2J\",\"envoy.path\":\"//evil/select/logsql/query?query=a%E2%80%AEb%1B%5D0%3Bx%07\",\"envoy.status\":\"200\"}"
    run "$OP" audit
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    f="$(report_file)"
    ! grep -q $'\033' "$f"; ! grep -q $'\007' "$f"; ! grep -q $'\u202e' "$f"
    grep -qx '    10:00:02  200  GET audit.internal?\[2J//evil/select/logsql/query' "$f" || { cat "$f"; return 1; }
    grep -qx '            a?b?\]0;x?' "$f"
}

@test "audit: an exit 64 without audit-run's own line is a run like any other (the report is kept)" {
    RC=64 run "$OP" audit
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    grep -q 'exit 64' "$(report_file)"
}

@test "audit-run: nothing a run wrote reaches the next: the box's ~/.claude but the login, claude.json but the account, the history" {
    st="$T/home/.config/claude-airlock/state/$(printf '%s' "$T/home/audit" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')"
    mkdir -p "$st/dot-claude/projects/x" "$st/dot-claude/todos" "$T/home/.claude/projects/old"
    echo '{"permissions":{"allow":["Bash"]},"env":{"BASH_ENV":"/x"}}' > "$st/dot-claude/settings.json"
    echo report > "$st/dot-claude/projects/x/earlier.jsonl"
    echo '{"token":"t"}' > "$st/dot-claude/.credentials.json"
    echo hidden > "$st/dot-claude/.hidden"; echo dots > "$st/dot-claude/..dots"
    ln -s /etc/passwd "$st/dot-claude/link"
    echo '{"oauthAccount":{"emailAddress":"a@example.org"},"userID":"u","projects":{"/w":{"allowedTools":["Bash"]}},"mcpServers":{"x":{}}}' > "$st/claude.json"
    echo old > "$T/home/.claude/projects/old/t.jsonl"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(ls -A "$st/dot-claude")" = .credentials.json ] || { ls -A "$st/dot-claude"; return 1; }
    [ "$(cat "$st/dot-claude/.credentials.json")" = '{"token":"t"}' ]
    [ "$(jq -c . "$st/claude.json")" = '{"oauthAccount":{"emailAddress":"a@example.org"},"userID":"u"}' ]
    [ ! -e "$T/home/.claude/projects" ]
    [ -e /etc/passwd ]
    # a login file that isn't a regular file goes too
    rm "$st/dot-claude/.credentials.json"; ln -s /etc/passwd "$st/dot-claude/.credentials.json"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 0 ]; [ -z "$(ls -A "$st/dot-claude")" ]
}

@test "audit-run: the launcher's scratch dir and artifact stores for the workspace are emptied too; the template keeps none" {
    slug="$(printf '%s' "$T/home/audit" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')"
    st="$T/home/.config/claude-airlock/state/$slug"
    mkdir -p "$st/artifacts/node_modules" "$st/artifacts-x" "$AIRLOCK_TMP_BASE/$slug/sub"
    echo note > "$st/artifacts/node_modules/note"; echo t > "$AIRLOCK_TMP_BASE/$slug/sub/t"; echo h > "$AIRLOCK_TMP_BASE/$slug/.h"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$st/artifacts" ] && [ ! -e "$st/artifacts-x" ]
    [ -d "$AIRLOCK_TMP_BASE/$slug" ] && [ -z "$(ls -A "$AIRLOCK_TMP_BASE/$slug")" ]
    grep -qx 'AIRLOCK_ARTIFACT_DIRS=' "$REPO/agents/templates/auditor.conf"
    grep -qx 'AIRLOCK_SHARE_HISTORY=0' "$REPO/agents/templates/auditor.conf"
}

@test "audit-run: refused while a box of the auditor's still runs, or when its state is a link" {
    RUNNING=abc123 run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 64 ]; [[ "$output" == *"is still running"* ]]
    [ ! -e "$CALLS.airlock" ]
    st="$T/home/.config/claude-airlock/state/$(printf '%s' "$T/home/audit" | sed 's#[^a-zA-Z0-9]#-#g; s#^-*##')"
    mkdir -p "$T/elsewhere" "$st"; echo '{}' > "$T/elsewhere/settings.json"; ln -s "$T/elsewhere" "$st/dot-claude"
    run "$REPO/agents/lib/audit-run" review 7
    [ "$status" -eq 64 ]; [[ "$output" == *"is a link"* ]]
    [ -f "$T/elsewhere/settings.json" ]
}

@test "audit: audit-run's refusal after other tools' errors still writes no report" {
    mkdir -p "$T/lib"
    printf '#!/bin/sh\necho "rm: cannot remove x: Permission denied"\necho "audit-run: could not empty y; nothing runs until it is"\nexit 64\n' > "$T/lib/audit-run"; chmod +x "$T/lib/audit-run"
    sed -i "s#^AGENTS_LIB=.*#AGENTS_LIB=$T/lib#" "$AIRLOCK_AGENTS_ENV"
    run "$OP" audit
    [ "$status" -ne 0 ]; [[ "$output" == *"no run, no report"* ]]
    [ -z "$(report_file)" ]
}
