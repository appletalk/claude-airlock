#!/usr/bin/env bats
# agents/operator audit denies: the fixed query, the join of a refused TLS name to its CONNECT,
# the hints, cleaning. curl is a stub that answers from fixtures by the query it is sent; the
# store's socket is a socket file nobody listens on. Nothing real is touched.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    T="$BATS_TEST_TMPDIR"
    OP="$REPO/agents/operator"
    export AIRLOCK_AGENTS_ENV="$T/agents.env"
    printf '%s\n' AGENTS_OPERATOR=alice AGENTS_COMMAND=agent AGENTS_AGENT=agent AGENTS_AGENT_UID=1100 \
        "AGENTS_INBOX=$T/inbox" AGENTS_WEB= AGENTS_WEB_UID= AGENTS_GUARD= AGENTS_GUARD_UID= AGENTS_QUEUE= AGENTS_AUDIT=on "AGENTS_LIB=$T/lib" > "$AIRLOCK_AGENTS_ENV"
    export AGENTS_AUDIT_SOCK="$T/vl.sock" CALLS="$T/calls" TZ=UTC HOME="$T/ophome"
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$AGENTS_AUDIT_SOCK"
    mkdir -p "$T/bin"
    # curl: records each query; a count answers COUNT (default: the rows' number), a CONNECT
    # lookup answers $T/connects, anything else $T/rows; CODE makes it an HTTP error
    cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
q=""; for a; do case "$a" in query=*) q=${a#query=} ;; esac; done
printf '%s\n' "$q" >> "$CALLS"
if [ -n "${CODE:-}" ]; then printf 'cannot parse query\n%s' "$CODE"; exit 0; fi
case "$q" in
    *'stats count() n'*) echo "{\"n\":\"${COUNT:-$(grep -c . "$(dirname "$CALLS")/rows")}\"}" ;;
    *'stats by (audit.severity) count() n'*) echo "{\"audit.severity\":\"high\",\"n\":\"${COUNT:-$(grep -c . "$(dirname "$CALLS")/rows")}\"}" ;;
    *envoy.method:CONNECT*) cat "$(dirname "$CALLS")/connects" 2>/dev/null ;;
    *) cat "$(dirname "$CALLS")/rows" ;;
esac
printf '\n200'
EOF
    chmod +x "$T/bin/curl"
    export PATH="$T/bin:$PATH"
    : > "$T/rows"; : > "$T/connects"
}

# Whatever a test started (the relay, the fake store) goes when it ends, failed or not: a test
# that stops early must never leave them holding bats' output (the file would hang to its
# timeout). The relay's output is printed, which bats shows only for a failed test.
teardown() {
    [ -z "${UI:-}" ] || kill "$UI" 2>/dev/null || true
    [ -z "${STORE:-}" ] || kill "$STORE" 2>/dev/null || true
    wait 2>/dev/null || true
    [ ! -f "$T/ui.out" ] || sed 's/^/ui.out: /' "$T/ui.out"
}
row() { printf '%s\n' "$1" >> "$T/rows"; }
denies() { run "$OP" audit denies "$@"; }

@test "the query is fixed: Envoy's own refusals since the window, newest first, limited" {
    denies --since 2h --limit 7
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    q="$(sed -n 1p "$CALLS")"
    pred='(audit.kind:in("envoy-refused","envoy-web-refused") or (audit.kind:"" log_type:in("envoy-access","envoy-web") (envoy.flags:NR or envoy.flags:UAEX or envoy.details:="lua_response" or envoy.details:~"^rbac_access_denied" or envoy.route:~"^deny-" or (log_type:envoy-web envoy.flags:~"UF|DF") or (envoy.status:>=400 -envoy.details:via_upstream -envoy.details:~"^(upstream_|no_healthy_upstream)" -envoy.details:~"timeout"))))'
    # the newest 10000 lines, whatever --limit says: it counts rows, after repeats collapse
    [[ "$q" == '_time:>='????-??-??T??:??:??Z" $pred | sort by (_time desc) | limit 10000 | fields "* ]] || { echo "$q"; return 1; }
    [[ "$(sed -n 2p "$CALLS")" == *'| stats count() n' ]]
    [[ "$output" == *"(no refusals since "* ]]
}

@test "a refused CONNECT, a preset's refusal and a locked credential: who, what, route, the site file line" {
    row '{"_time":"2026-11-15T14:02:11.5Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"12","envoy.method":"CONNECT","envoy.authority":"example.org:443","envoy.path":"","envoy.route":"deny-connect","envoy.status":"403","envoy.flags":"-","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:01:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"11","envoy.method":"POST","envoy.authority":"git.example.org","envoy.path":"/api/v1/repos/a/b/merge","envoy.route":"git.example.org-refused","envoy.status":"403","envoy.flags":"-","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:00:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"GET","envoy.authority":"git.example.org","envoy.path":"/","envoy.route":"git.example.org-read","envoy.status":"423","envoy.details":"lua_response"}'
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == "2026-11-15 14:02:11  agent            agent-infra              403  CONNECT example.org:443  [deny-connect]" ]]
    [[ "${lines[1]}" == "    example.org:443 is not a destination of agent-infra: add it to the agent-infra lines" ]]
    [[ "${lines[2]}" == *"POST git.example.org/api/v1/repos/a/b/merge  [git.example.org-refused]" ]]
    [[ "${lines[3]}" == *"refused by the rules of git.example.org: its http line"* ]]
    [[ "${lines[5]}" == *"locked: airlock-envoy-cred unlock" ]]
    [[ "${lines[6]}" == "(3 refusals in 3 rows since "*"; the site file: /etc/airlock-envoy/site.conf)" ]]
}

@test "a refused TLS name gets its user from the latest CONNECT before it with that connection id" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"sni-x","envoy.connection":"40","envoy.sni":"other.example.org","envoy.route":"","envoy.flags":"NR"}'
    # the same id twice in the window: the later one wins; one after the window doesn't count
    printf '%s\n' \
        '{"_time":"2026-11-15T14:04:45Z","envoy.connection":"40","envoy.user":"old","envoy.listener":"old-l","envoy.authority":"old.example.org:443"}' \
        '{"_time":"2026-11-15T14:04:59Z","envoy.connection":"40","envoy.user":"agent","envoy.listener":"agent-infra","envoy.authority":"svc.example.org:443"}' \
        '{"_time":"2026-11-15T14:09:00Z","envoy.connection":"40","envoy.user":"later","envoy.listener":"later-l","envoy.authority":"later.example.org:443"}' > "$T/connects"
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"agent            agent-infra                -  TLS other.example.org in a tunnel to svc.example.org:443  [no route NR]" ]]
    [[ "${lines[1]}" == "    the tunnel to svc.example.org:443 sent the TLS name other.example.org: only svc.example.org passes" ]]
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == *'envoy.connection:in(40) '* ]]
}

@test "the join takes only a CONNECT from 20 s before to 3 s after: an older tunnel with the same id is not a guess" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"40","envoy.sni":"other.example.org","envoy.flags":"NR"}'
    printf '%s\n' '{"_time":"2026-11-15T14:04:30Z","envoy.connection":"40","envoy.user":"agent2","envoy.listener":"agent2-l","envoy.authority":"x.example.org:443"}' > "$T/connects"
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"  ?                ?                          -  TLS other.example.org in a tunnel to ?  "* ]] || { echo "$output"; return 1; }
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == '(_time:[2026-11-15T14:04:40Z, 2026-11-15T14:05:04Z]) log_type:envoy-access envoy.method:CONNECT envoy.log_type:in(DownstreamTunnelSuccessfullyEstablished,DownstreamEnd) envoy.connection:in(40) | sort by (_time desc) | limit 10000 '* ]] || { echo "$q"; return 1; }
}

@test "the CONNECT lookup is one window per refusal (merged where they overlap), not one span over all" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"7","envoy.sni":"a.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-15T14:04:50Z","log_type":"envoy-access","envoy.connection":"8","envoy.sni":"b.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-05T14:00:00Z","log_type":"envoy-access","envoy.connection":"9","envoy.sni":"c.example.org","envoy.flags":"NR"}'
    denies --since 30d
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == '(_time:[2026-11-05T13:59:40Z, 2026-11-05T14:00:04Z] or _time:[2026-11-15T14:04:30Z, 2026-11-15T14:05:04Z]) '*'envoy.connection:in(7,8,9) '* ]] || { echo "$q"; return 1; }
}

@test "many refused TLS names over a long look-back: the lookup goes in batches, each query under 16 KiB" {
    for i in $(seq 0 349); do
        printf '{"_time":"%s","log_type":"envoy-access","envoy.connection":"%d","envoy.sni":"n%d.example.org","envoy.flags":"NR"}\n' \
            "$(date -u -d "2026-11-15T14:00:00Z - $((i * 60)) seconds" +%Y-%m-%dT%H:%M:%SZ)" "$((100000 + i))" "$i" >> "$T/rows"
    done
    denies --since 30d --limit 1000
    [ "$status" -eq 0 ] || { echo "$output" | tail -3; return 1; }
    n=0; while IFS= read -r q; do
        [[ "$q" == *envoy.method:CONNECT* ]] || continue
        n=$((n + 1)); [ "${#q}" -lt 16384 ] || { echo "query $n is ${#q} bytes"; return 1; }
    done < "$CALLS"
    [ "$n" -ge 2 ] || { echo "$n lookups"; return 1; }
    for i in 0 99 100 349; do grep -q "envoy.connection:in([0-9,]*$((100000 + i))[,)]" "$CALLS" || { echo "id $((100000 + i)) never looked up"; return 1; }; done
    # each batch asks only for its own windows' ids: the first (oldest) batch not for the newest refusal's
    first="$(grep -m1 envoy.method:CONNECT "$CALLS")"
    [[ "$first" == *"100349"* && "$first" != *"100000"* ]] || { echo "${first:0:300}"; return 1; }
}

@test "a burst of refused TLS names in one window with long ids: split across queries, each under 16 KiB" {
    for i in $(seq 0 999); do
        printf '{"_time":"2026-11-15T14:00:%02d.%03dZ","log_type":"envoy-access","envoy.connection":"1%019d","envoy.sni":"n.example.org","envoy.flags":"NR"}\n' \
            "$((i / 50))" "$((i % 50))" "$i" >> "$T/rows"
    done
    denies --limit 1000
    [ "$status" -eq 0 ] || { echo "$output" | tail -3; return 1; }
    n=0; while IFS= read -r q; do
        [[ "$q" == *envoy.method:CONNECT* ]] || continue
        n=$((n + 1)); [ "${#q}" -lt 16384 ] || { echo "query $n is ${#q} bytes"; return 1; }
    done < "$CALLS"
    [ "$n" -ge 2 ] || { echo "$n lookups"; return 1; }
    for i in 0 500 999; do grep -q "$(printf '1%019d' "$i")[,)]" "$CALLS" || { echo "id $i never looked up"; return 1; }; done
}

@test "an HTTP line without a method (the parser refused it) is not taken for a TLS refusal or joined" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"7","envoy.status":"400","envoy.details":"http1.codec_error"}'
    printf '%s\n' '{"_time":"2026-11-15T14:04:59Z","envoy.connection":"7","envoy.user":"other","envoy.listener":"other-l","envoy.authority":"old.example.org:443"}' > "$T/connects"
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"agent            agent-infra              400  (a request Envoy could not read) "* ]] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    Envoy refused the request itself (http1.codec_error)" ]
    ! grep -q CONNECT "$CALLS" || return 1
}

@test "hints by what Envoy did: no token, a body too large, a protected branch, the push check failing, web unreachable" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/","envoy.route":"a.example.org-read","envoy.status":"503","envoy.details":"lua_response"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"m.example.org","envoy.path":"/mcp","envoy.route":"m.example.org-ep0-post-too-large","envoy.status":"413","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:03:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"g.example.org","envoy.path":"/o/r/git-receive-pack","envoy.route":"g.example.org-push-guard","envoy.status":"200","envoy.flags":"UAEX","envoy.details":"ext_authz_denied"}'
    row '{"_time":"2026-11-15T14:02:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"g.example.org","envoy.path":"/o/r/git-receive-pack","envoy.route":"g.example.org-push-guard","envoy.status":"503","envoy.flags":"UAEX","envoy.details":"ext_authz_error"}'
    row '{"_time":"2026-11-15T14:01:00Z","log_type":"envoy-web","envoy.listener":"w","envoy.user":"agent","envoy.sni":"n.example.org","envoy.route":"web","envoy.flags":"UF"}'
    row '{"_time":"2026-11-15T14:00:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/x_y","envoy.route":"a.example.org-read","envoy.status":"400","envoy.details":"http1.unexpected_underscore"}'
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    the credential for a.example.org has no token (airlock-envoy-cred)" ] || { echo "$output"; return 1; }
    [ "${lines[3]}" = "    a body over the limit of the rules of m.example.org (its http line)" ]
    [ "${lines[5]}" = "    a push to a protected branch of g.example.org: protect on its http line" ]
    [ "${lines[7]}" = "    the push check for g.example.org could not decide, so the push was refused (it fails closed)" ]
    [ "${lines[9]}" = "    web could not connect to n.example.org (down, or an internal address its kernel filter refuses)" ]
    [ "${lines[11]}" = "    Envoy refused the request itself (http1.unexpected_underscore)" ]
}

@test "hints: an MCP tool refused (a 200 from Envoy's Lua), the push check's own 400, a buffered body too large" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"m.example.org","envoy.path":"/mcp","envoy.route":"m.example.org-ep0-post","envoy.status":"200","envoy.details":"lua_response"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"g.example.org","envoy.path":"/o/r/git-receive-pack","envoy.route":"g.example.org-push-guard","envoy.status":"400","envoy.flags":"UAEX","envoy.details":"ext_authz_denied"}'
    row '{"_time":"2026-11-15T14:03:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"api.example.org","envoy.path":"/graphql","envoy.route":"api.example.org-graphql","envoy.status":"413","envoy.details":"request_payload_too_large"}'
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    a tool call the mcp rules of m.example.org refuse: tools or deny-tools on its http line" ] || { echo "$output"; return 1; }
    [ "${lines[3]}" = "    the push check refused the push to g.example.org (Envoy's own log says why)" ]
    [ "${lines[5]}" = "    a body over the limit of the rules of api.example.org (its http line)" ]
}

@test "an SNI line with no CONNECT to join shows no user rather than a guess; a bad id is never queried" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"41","envoy.sni":"x.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.connection":"1) or (x","envoy.sni":"y.example.org","envoy.flags":"NR"}'
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"  ?                ?                          -  TLS x.example.org in a tunnel to ?  "* ]]
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == *'envoy.connection:in(41) '* && "$q" != *"or (x"* ]]
}

@test "web's internal-name refusal, an address entry's RBAC refusal" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-web","envoy.listener":"agent-web","envoy.user":"agent","envoy.sni":"metrics.example.org","envoy.route":"deny-internal-name"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.connection":"5","envoy.sni":"one.example.org","envoy.route":"tls-no-sni","envoy.details":"rbac_access_denied_matched_policy[server-name-sent]"}'
    printf '%s\n' '{"_time":"2026-11-15T14:03:55Z","envoy.connection":"5","envoy.user":"agent","envoy.listener":"agent-infra","envoy.authority":"10.99.0.1:6443"}' > "$T/connects"
    denies --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"web TLS metrics.example.org  [deny-internal-name]" ]]
    [[ "${lines[1]}" == *"metrics.example.org is an internal name: web never reaches one"* ]]
    [[ "${lines[3]}" == "    10.99.0.1:6443 is an address entry, which passes only TLS without a name; the client sent one.example.org" ]]
}

@test "the agents' text is cleaned: no escape sequence or control byte reaches the terminal" {
    row "$(printf '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/\\u001b]52;c;aGk=\\u0007x\\u009b31m","envoy.route":"deny-http","envoy.status":"403"}')"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! printf '%s' "$output" | LC_ALL=C grep -qP '[\x00-\x08\x0b-\x1f\x7f]|\xc2[\x80-\x9f]' || return 1
    [[ "${lines[0]}" == *"GET a.example.org/?]52;c;aGk=?x?31m  [deny-http]" ]]
}

@test "more than shown: the closing line says so" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.user":"agent","envoy.listener":"agent-infra","envoy.method":"CONNECT","envoy.authority":"a.example.org:443","envoy.route":"deny-connect","envoy.status":"403"}'
    COUNT=312 denies --limit 1 --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[2]}" == "(1 row, 1 of 312 refusals, since "*", newest first: --limit <n> for more)" ]] || { echo "$output"; return 1; }
}

@test "repeats in a row are one row with their count and when the run began; each reason once, numbered, below" {
    c='"log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"CONNECT","envoy.authority":"a.example.org:443","envoy.route":"deny-connect","envoy.status":"403","envoy.details":"direct_response"'
    p='"log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"POST","envoy.authority":"api.example.org","envoy.path":"/graphql","envoy.route":"api.example.org-refused","envoy.status":"403","envoy.details":"direct_response"'
    row "{\"_time\":\"2026-11-15T14:05:00Z\",\"envoy.connection\":\"3\",$c}"
    row "{\"_time\":\"2026-11-15T14:04:00Z\",\"envoy.connection\":\"2\",$c}"
    row "{\"_time\":\"2026-11-15T14:03:00Z\",\"envoy.connection\":\"1\",$c}"
    row "{\"_time\":\"2026-11-15T14:02:00Z\",$p}"
    row "{\"_time\":\"2026-11-15T14:01:00Z\",\"envoy.connection\":\"9\",$c}"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[0]}" = "2026-11-15 14:05:00  agent            agent-infra              403  #1   CONNECT a.example.org:443 (x3, from 14:03:00)  [deny-connect]" ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "2026-11-15 14:02:00  agent            agent-infra              403  #2   POST api.example.org/graphql  [api.example.org-refused]" ]
    # alike but not in a row: a row of its own, the same note
    [ "${lines[2]}" = "2026-11-15 14:01:00  agent            agent-infra              403  #1   CONNECT a.example.org:443  [deny-connect]" ]
    [ "${lines[3]}" = "#1    a.example.org:443 is not a destination of agent-infra: add it to the agent-infra lines" ]
    [[ "${lines[4]}" == "#2    refused by the rules of api.example.org: its http line"* ]]
    [[ "${lines[5]}" == "(5 refusals in 3 rows since "*"; the site file: /etc/airlock-envoy/site.conf)" ]]
    [ "${#lines[@]}" -eq 6 ]
    # --full: the reason under every row, no numbers or notes
    denies --full
    [ "${lines[0]}" = "2026-11-15 14:05:00  agent            agent-infra              403  CONNECT a.example.org:443 (x3, from 14:03:00)  [deny-connect]" ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    a.example.org:443 is not a destination of agent-infra: add it to the agent-infra lines" ]
    [ "${lines[5]}" = "    a.example.org:443 is not a destination of agent-infra: add it to the agent-infra lines" ]
    [[ "${lines[6]}" == "(5 refusals in 3 rows since "* ]]
}

@test "refusals that differ in any logged field are not collapsed: path, user, status, details" {
    b='"log_type":"envoy-access","envoy.listener":"l","envoy.method":"GET","envoy.authority":"a.example.org","envoy.route":"a.example.org-refused"'
    row "{\"_time\":\"2026-11-15T14:05:00Z\",$b,\"envoy.user\":\"agent\",\"envoy.path\":\"/x\",\"envoy.status\":\"403\",\"envoy.details\":\"direct_response\"}"
    row "{\"_time\":\"2026-11-15T14:04:00Z\",$b,\"envoy.user\":\"agent\",\"envoy.path\":\"/y\",\"envoy.status\":\"403\",\"envoy.details\":\"direct_response\"}"
    row "{\"_time\":\"2026-11-15T14:03:00Z\",$b,\"envoy.user\":\"agent2\",\"envoy.path\":\"/y\",\"envoy.status\":\"403\",\"envoy.details\":\"direct_response\"}"
    row "{\"_time\":\"2026-11-15T14:02:00Z\",$b,\"envoy.user\":\"agent2\",\"envoy.path\":\"/y\",\"envoy.status\":\"423\",\"envoy.details\":\"lua_response\"}"
    row "{\"_time\":\"2026-11-15T14:01:00Z\",$b,\"envoy.user\":\"agent2\",\"envoy.path\":\"/y\",\"envoy.status\":\"423\",\"envoy.details\":\"lua_response2\"}"
    # each of these differs from the one before in one field only: listener, flags, authority, log_type
    l='"envoy.user":"agent2","envoy.method":"GET","envoy.path":"/y","envoy.route":"a.example.org-refused","envoy.status":"423","envoy.details":"lua_response2"'
    row "{\"_time\":\"2026-11-15T14:00:50Z\",\"log_type\":\"envoy-access\",\"envoy.listener\":\"l2\",\"envoy.authority\":\"a.example.org\",$l}"
    row "{\"_time\":\"2026-11-15T14:00:40Z\",\"log_type\":\"envoy-access\",\"envoy.listener\":\"l2\",\"envoy.authority\":\"a.example.org\",\"envoy.flags\":\"UAEX\",$l}"
    row "{\"_time\":\"2026-11-15T14:00:30Z\",\"log_type\":\"envoy-access\",\"envoy.listener\":\"l2\",\"envoy.authority\":\"b.example.org\",\"envoy.flags\":\"UAEX\",$l}"
    row "{\"_time\":\"2026-11-15T14:00:20Z\",\"log_type\":\"envoy-web\",\"envoy.listener\":\"l2\",\"envoy.authority\":\"b.example.org\",\"envoy.flags\":\"UAEX\",$l}"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"(9 refusals in 9 rows since "* ]] || { echo "$output"; return 1; }
    ! grep -q '(x' <<< "$output" || return 1
}

@test "refused TLS names in a row joined to different users are two rows; the same TLS name in one tunnel each, one user, is one" {
    row '{"_time":"2026-11-15T14:05:10Z","log_type":"envoy-access","envoy.connection":"51","envoy.sni":"x.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"50","envoy.sni":"x.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-15T14:04:50Z","log_type":"envoy-access","envoy.connection":"49","envoy.sni":"x.example.org","envoy.flags":"NR"}'
    printf '%s\n' \
        '{"_time":"2026-11-15T14:05:09Z","envoy.connection":"51","envoy.user":"alice","envoy.listener":"l1","envoy.authority":"svc.example.org:443"}' \
        '{"_time":"2026-11-15T14:04:59Z","envoy.connection":"50","envoy.user":"agent","envoy.listener":"l2","envoy.authority":"svc.example.org:443"}' \
        '{"_time":"2026-11-15T14:04:49Z","envoy.connection":"49","envoy.user":"agent","envoy.listener":"l2","envoy.authority":"svc.example.org:443"}' > "$T/connects"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"alice            l1 "*"TLS x.example.org in a tunnel to svc.example.org:443  [no route NR]" ]] || { echo "$output"; return 1; }
    [[ "${lines[1]}" == *"agent            l2 "*"TLS x.example.org in a tunnel to svc.example.org:443 (x2, from 14:04:50)  [no route NR]" ]]
}

@test "the newest 10000 lines read: the closing line says so even at --limit, and the last run is marked open-ended" {
    python3 -c '
import json
for i in range(10000):
    print(json.dumps({"_time": "2026-11-15T14:00:00Z",
                      "log_type": "envoy-access", "envoy.listener": "l", "envoy.user": "agent", "envoy.method": "CONNECT",
                      "envoy.authority": ("a" if i < 5000 else "b") + ".example.org:443", "envoy.route": "deny-connect", "envoy.status": "403"}))' > "$T/rows"
    COUNT=20000 denies --limit 2
    [ "$status" -eq 0 ] || { echo "$output" | tail -3; return 1; }
    [[ "${lines[0]}" == *"CONNECT a.example.org:443 (x5000, from 14:00:00)  [deny-connect]" ]] || { echo "$output" | head -3; return 1; }
    [[ "${lines[1]}" == *"CONNECT b.example.org:443 (x5000+, from 14:00:00)  [deny-connect]" ]]
    [[ "${lines[-1]}" == "(2 rows, 10000 of 20000 refusals, since "*"only the newest 10000 were read, so older refusals are not shown and the last count may be low)" ]] || { echo "${lines[-1]}"; return 1; }
    # stopped by --limit before the lines ran out: no mark, and --limit is the way to more
    COUNT=20000 denies --limit 1
    [[ "${lines[0]}" == *"(x5000, from 14:00:00)  [deny-connect]" ]] || { echo "$output" | head -3; return 1; }
    [[ "${lines[-1]}" == "(1 row, 5000 of 20000 refusals, since "*"--limit <n> for more)" ]]
}

@test "the CONNECT lookup stops with the rows: TLS names past the last row shown cost no query" {
    python3 -c '
import json
for i in range(600):
    print(json.dumps({"_time": "2026-11-15T14:00:00Z", "log_type": "envoy-access", "envoy.listener": "l", "envoy.user": "agent",
                      "envoy.method": "CONNECT", "envoy.authority": ("a" if i == 0 else "b") + ".example.org:443",
                      "envoy.route": "deny-connect", "envoy.status": "403"}))
for i in range(600):
    print(json.dumps({"_time": "2026-11-15T13:00:00Z", "log_type": "envoy-access", "envoy.connection": str(7000 + i),
                      "envoy.sni": "n.example.org", "envoy.flags": "NR"}))' > "$T/rows"
    denies --limit 2
    [ "$status" -eq 0 ] || { echo "$output" | tail -3; return 1; }
    ! grep -q envoy.method:CONNECT "$CALLS" || { echo "looked up past the rows shown"; return 1; }
    # a third row needs them: then they are looked up
    denies --limit 3
    grep -q 'envoy.connection:in(7000,' "$CALLS" || return 1
}

@test "a run of one TLS name longer than a lookup chunk (500) is still one row, fully counted" {
    python3 -c '
import json
for i in range(600):
    print(json.dumps({"_time": "2026-11-15T14:00:00Z", "log_type": "envoy-access", "envoy.connection": str(8000 + i),
                      "envoy.sni": "x.example.org", "envoy.flags": "NR"}))' > "$T/rows"
    python3 -c '
import json
for i in range(600):
    print(json.dumps({"_time": "2026-11-15T13:59:59Z", "envoy.connection": str(8000 + i), "envoy.user": "agent",
                      "envoy.listener": "l", "envoy.authority": "svc.example.org:443"}))' > "$T/connects"
    denies --limit 1
    [ "$status" -eq 0 ] || { echo "$output" | tail -3; return 1; }
    [[ "${lines[0]}" == *"TLS x.example.org in a tunnel to svc.example.org:443 (x600, from 14:00:00)  [no route NR]" ]] || { echo "${lines[0]}"; return 1; }
    [[ "${lines[-1]}" == "(600 refusals in 1 row since "* ]]
}

@test "a narrow terminal (80, 100 columns): the host and the run count stay on the row" {
    command -v script >/dev/null || skip "no script(1) to give the command a terminal"
    c='"log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"CONNECT","envoy.authority":"a.example.org:443","envoy.route":"deny-connect","envoy.status":"403"'
    for i in 5 4 3; do row "{\"_time\":\"2026-11-15T14:0${i}:00Z\",$c}"; done
    for w in 80 100; do
        out="$(script -qec "stty cols $w rows 40; '$OP' audit denies" /dev/null | tr -d '\r')"
        first="$(head -1 <<< "$out")"
        [[ "$first" == *"CONNECT a.example.org:443 (x3"* ]] || { echo "$w: $first"; return 1; }
        while IFS= read -r l; do [ "${#l}" -le "$w" ] || { echo "$w: too wide: $l"; return 1; }; done <<< "$out"
    done
}

@test "a reason exactly as wide as its line stays one line; one column more wraps" {
    for extra in 0 1; do
        : > "$T/rows"
        base="web could not connect to .example.org (down, or an internal address its kernel filter refuses)"
        sni="$(printf 'a%.0s' $(seq 1 $((194 - ${#base} + extra)))).example.org"
        row "{\"_time\":\"2026-11-15T14:01:00Z\",\"log_type\":\"envoy-web\",\"envoy.listener\":\"w\",\"envoy.user\":\"agent\",\"envoy.sni\":\"$sni\",\"envoy.route\":\"web\",\"envoy.flags\":\"UF\"}"
        denies
        [ "$status" -eq 0 ] || { echo "$output"; return 1; }
        n="$(grep -c . <<< "$output")"
        [ "$n" -eq $((3 + extra)) ] || { echo "extra $extra: $n lines"; echo "$output"; return 1; }
    done
}

@test "a long path never hides the run count, and a reason in wide or non-ASCII text stays whole and valid UTF-8" {
    long="/$(printf 'a%.0s' $(seq 1 150))"
    for i in 1 2 3; do row "{\"_time\":\"2026-11-15T14:0$((6 - i)):00Z\",\"log_type\":\"envoy-access\",\"envoy.listener\":\"l\",\"envoy.user\":\"agent\",\"envoy.method\":\"GET\",\"envoy.authority\":\"a.example.org\",\"envoy.path\":\"$long\",\"envoy.route\":\"deny-http\",\"envoy.status\":\"403\"}"; done
    sni="$(printf 'é%.0s' $(seq 1 20))$(printf '界%.0s' $(seq 1 60)).example.org"
    row "{\"_time\":\"2026-11-15T14:01:00Z\",\"log_type\":\"envoy-web\",\"envoy.listener\":\"w\",\"envoy.user\":\"agent\",\"envoy.sni\":\"$sni\",\"envoy.route\":\"web\",\"envoy.flags\":\"UF\"}"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    # what is shortened so the count shows; the route tag after it is what the width cuts
    [[ "${lines[0]}" == *"aaa... (x3, from 14:03:00)  [de"* ]] || { echo "${lines[0]}"; return 1; }
    printf '%s' "$output" | iconv -f UTF-8 -t UTF-8 >/dev/null || { echo "invalid UTF-8"; return 1; }
    # the note wrapped, not cut: its tail is there
    [[ "$(tr '\n' ' ' <<< "$output" | tr -s ' ')" == *"(down, or an internal address its kernel filter refuses)"* ]] || { echo "$output"; return 1; }
    # wrapped at a space, never mid-word
    grep -q 'an int$' <<< "$output" && return 1
    while IFS= read -r l; do
        [ "$(printf '%s' "$l" | python3 -c 'import sys,unicodedata; print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in sys.stdin.read()))')" -le 200 ] || { echo "too wide: $l"; return 1; }
    done <<< "$output"
}

@test "--limit counts rows, not lines: a long run is one row, and the closing line counts both" {
    c='"log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"CONNECT","envoy.authority":"a.example.org:443","envoy.route":"deny-connect","envoy.status":"403"'
    for i in 5 4 3 2 1; do row "{\"_time\":\"2026-11-15T14:0${i}:00Z\",$c}"; done
    row '{"_time":"2026-11-15T13:00:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"CONNECT","envoy.authority":"b.example.org:443","envoy.route":"deny-connect","envoy.status":"403"}'
    denies --limit 1
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"CONNECT a.example.org:443 (x5, from 14:01:00)  [deny-connect]" ]] || { echo "$output"; return 1; }
    [[ "${lines[-1]}" == "(1 row, 5 of 6 refusals, since "*", newest first: --limit <n> for more)" ]]
    ! grep -q 'b.example.org' <<< "$output" || return 1
    # a run begun the day before keeps its date
    : > "$T/rows"
    row "{\"_time\":\"2026-11-15T00:01:00Z\",$c}"; row "{\"_time\":\"2026-11-14T23:59:00Z\",$c}"
    denies --since 30d
    [[ "${lines[0]}" == *"CONNECT a.example.org:443 (x2, from 2026-11-14 23:59:00)  [deny-connect]" ]] || { echo "$output"; return 1; }
}

@test "the store unreachable or refusing: an error, exit 1; no audit store: says how to turn it on" {
    CODE=400 denies
    [ "$status" -eq 1 ]; [[ "$output" == *"no answer from the audit store (curl 0, HTTP 400): cannot parse query"* ]]
    sed -i 's/^AGENTS_AUDIT=on$/AGENTS_AUDIT=off/' "$AIRLOCK_AGENTS_ENV"
    denies
    [ "$status" -eq 1 ]; [[ "$output" == *"no audit store here (agents.conf: audit on"* ]]
    sed -i 's/^AGENTS_AUDIT=off$/AGENTS_AUDIT=on/' "$AIRLOCK_AGENTS_ENV"; rm -f "$AGENTS_AUDIT_SOCK"
    denies
    [ "$status" -eq 1 ]; [[ "$output" == *"socket $AGENTS_AUDIT_SOCK is missing"* ]]
}

@test "bad arguments are refused before any query" {
    for a in "--limit 0" "--limit 1001" "--limit x" "--since 5m" "--frob"; do
        # shellcheck disable=SC2086
        denies $a
        [ "$status" -ne 0 ] || { echo "accepted: $a"; return 1; }
    done
    # bare audit is the auditor's review: none here, so refused before any query
    run "$OP" audit; [ "$status" -ne 0 ]; [[ "$output" == *"no auditor here"* ]]
    run "$OP" audit --frob; [ "$status" -ne 0 ]; [[ "$output" == *"usage: agent audit [--days <n>]"* ]]
    [ ! -s "$CALLS" ]
}

@test "audit works while the agents are halted (it reads only the store); other commands don't" {
    mkdir -p "$T/home/.local/state/airlock-agents"; : > "$T/home/.local/state/airlock-agents/halting"
    HOME="$T/home" run "$OP" audit denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    HOME="$T/home" run "$OP" ls
    [ "$status" -ne 0 ]; [[ "$output" == *"halted"* ]]
}

# ---- audit ui ----------------------------------------------------------------------------------
# A fake store on a Unix socket (echoes what reached it), the relay on a free port.
ui_setup() {
    rm -f "$AGENTS_AUDIT_SOCK"
    cat > "$T/store.py" <<'PY'
import http.server, json, os, socket, socketserver, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        with open(sys.argv[1] + ".paths", "a") as f:   # what reached the store, one path a line
            f.write(self.path + "\n")
        if self.path.startswith("/stream"):  # three chunks, a second apart; /stream-stall stops after one
            self.send_response(200); self.send_header("Transfer-Encoding", "chunked"); self.end_headers()
            for i in range(3):
                self.wfile.write(b"5\r\nrow%d\n\r\n" % i); self.wfile.flush()
                if self.path == "/stream-stall": time.sleep(30)
                time.sleep(1)
            self.wfile.write(b"0\r\n\r\n"); return
        b = json.dumps({"path": self.path, "headers": dict(self.headers)}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("X-Store", "yes")
        self.end_headers(); self.wfile.write(b)
    do_POST = do_GET
class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    def get_request(self):
        r, _ = super().get_request(); return r, ("local", 0)
S(sys.argv[1], H).serve_forever()
PY
    python3 "$T/store.py" "$AGENTS_AUDIT_SOCK" > "$T/store.out" 2>&1 3>&- & STORE=$!
    PORT=0   # the relay picks a free one; ui_wait reads it back (no port taken in between)
    for _ in $(seq 150); do [ -S "$AGENTS_AUDIT_SOCK" ] && return 0; sleep 0.1; done
    echo "the fake store didn't start:"; cat "$T/store.out"; return 1
}
ui_read() {  # PORT, TOKEN, NAME from the relay's printed URL; fails if the line isn't there
    grep -q 'audit store' "$T/ui.out" 2>/dev/null || return 1
    TOKEN="$(sed -n 's|.*/select/vmui/?token=\([A-Za-z0-9_-]*\).*|\1|p' "$T/ui.out" | head -1)"
    NAME="$(sed -n 's|.*UI: http://\([^:/]*\):.*|\1|p' "$T/ui.out" | head -1)"
    PORT="$(sed -n 's|.*UI: http://[^:/]*:\([0-9]*\)/.*|\1|p' "$T/ui.out" | head -1)"
    [ -n "$TOKEN" ] && [ -n "$PORT" ]
}
ui_wait() {  # the relay started as UI: wait up to 15 s for its line (stop early if it died)
    for _ in $(seq 150); do
        ui_read && return 0
        kill -0 "$UI" 2>/dev/null || break
        sleep 0.1
    done
    ui_read && return 0   # printed just as it ended
    echo "the relay didn't start:"; cat "$T/ui.out"; return 1
}
ui_start() {  # ui_start <uid|off> [idle most]: the relay on a free port; PORT, TOKEN, NAME set
    : > "$T/ui.out"
    python3 -I "$REPO/agents/lib/audit-ui" "$AGENTS_AUDIT_SOCK" "${UI_PORT:-0}" "$@" > "$T/ui.out" 2>&1 3>&- & UI=$!
    ui_wait
}
ucurl() { /usr/bin/curl --noproxy "*" -b "audit_ui_$PORT=$TOKEN" "$@"; }   # with this run's cookie
ui_teardown() { kill "$UI" "$STORE" 2>/dev/null || true; wait 2>/dev/null || true; UI= STORE=; }

@test "audit ui: serves its own uid under its own Host, forwards only the listed headers" {
    ui_setup; ui_start "$(id -u)"
    r="$(/usr/bin/curl --noproxy "*" -s -H "Cookie: s=1; audit_ui_$PORT=$TOKEN" -H 'X-Forwarded-For: 1.2.3.4' "http://127.0.0.1:$PORT/select/vmui/?q=1")"
    ui_teardown
    [[ "$r" == *'"path": "/select/vmui/?q=1"'* ]] || { echo "$r"; return 1; }
    [[ "$r" != *Cookie* && "$r" != *X-Forwarded* && "$r" == *'"Host": "x"'* ]]
}

@test "audit ui: another Host (a rebound name) gets 421, nothing reaches the store" {
    ui_setup; ui_start "$(id -u)"
    c="$(ucurl -s -o "$T/body" -w '%{http_code}' -H 'Host: evil.example.org' "http://127.0.0.1:$PORT/select/vmui/")"
    c2="$(ucurl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/select/vmui/")"
    ui_teardown
    [ "$c" = 421 ] && [ "$c2" = 200 ] || { echo "$c $c2"; return 1; }
    ! grep -q path "$T/body" || return 1
}

@test "audit ui: no other site: a foreign Origin or a cross-site fetch is 403, no CORS header ever goes out, no preflight" {
    ui_setup; ui_start "$(id -u)"
    u="http://127.0.0.1:$PORT/select/logsql/query?query=*"
    o="$(ucurl -s -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example.org' "$u")"
    f="$(ucurl -s -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: cross-site' "$u")"
    n="$(ucurl -s -o /dev/null -w '%{http_code}' -H 'Origin: null' "$u")"
    ss="$(ucurl -s -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: same-site' "$u")"
    s="$(ucurl -s -D - -o /dev/null -H "Origin: http://127.0.0.1:$PORT" -H 'Sec-Fetch-Site: same-origin' "$u")"
    p="$(ucurl -s -o /dev/null -w '%{http_code}' -X OPTIONS -H "Origin: https://evil.example.org" "$u")"
    ui_teardown
    [ "$o" = 403 ] && [ "$f" = 403 ] && [ "$n" = 403 ] && [ "$ss" = 403 ] || { echo "$o $f $n $ss"; return 1; }
    [[ "$s" == "HTTP/1.0 200 "* ]] || { echo "$s"; return 1; }
    ! grep -qi '^access-control-' <<< "$s" || return 1
    grep -q $'^Server: audit-ui\r$' <<< "$s" || return 1
    [ "$(grep -ci '^server:' <<< "$s")" = 1 ] && grep -q '^X-Store: yes' <<< "$s" || return 1   # the store's own Server is not passed
    [[ "$p" == 4* || "$p" == 5* ]] && [ "$p" != 200 ]
}

@test "audit ui: a request it serves counts as use: idle 2 s, a request every 0.5 s for 4 s keeps it open" {
    ui_setup; ui_start "$(id -u)" 2 600
    for _ in 1 2 3 4 5 6 7 8; do ucurl -s -o /dev/null "http://127.0.0.1:$PORT/select/vmui/" || true; sleep 0.5; done
    open=0; kill -0 "$UI" 2>/dev/null && open=1
    ui_teardown
    [ "$open" = 1 ] || { cat "$T/ui.out"; return 1; }
}

@test "audit ui: refused requests don't hold off the idle limit; a control byte is a 400, no traceback" {
    ui_setup; ui_start "$(id -u)" 2 600
    c="$(printf 'GET /select/a\001b HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n' "$PORT" | python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1]))); s.sendall(sys.stdin.buffer.read()); print(s.recv(100).split(b"\r\n")[0].decode())' "$PORT")"
    # Clients that send a refused request and reset at once (the server's answer meets a dead
    # socket): never a traceback.
    python3 -c '
import socket, struct, sys
for _ in range(20):
    try:
        s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
        s.sendall(b"GET /select/a\x01b HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n" % sys.argv[1].encode())
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close()
    except OSError:
        pass' "$PORT" || true
    for _ in 1 2 3 4 5 6; do ucurl -s -o /dev/null -H 'Host: evil.example.org' "http://127.0.0.1:$PORT/" || true; sleep 0.5; done
    gone=1; kill -0 "$UI" 2>/dev/null && gone=0
    ui_teardown
    [[ "$c" == "HTTP/1.0 400 "* ]] || { echo "$c"; return 1; }
    [ "$gone" = 1 ] || { echo "still open after 3 s of refused requests with idle 2 s"; return 1; }
    ! grep -q Traceback "$T/ui.out" || { cat "$T/ui.out"; return 1; }
}

@test "audit ui: a folded header or an absolute-form target is a 400 and never reaches the store" {
    ui_setup; ui_start "$(id -u)"
    raw() { printf "$1" "$PORT" | python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1]))); s.sendall(sys.stdin.buffer.read()); print(s.recv(200).split(b"\r\n")[0].decode())' "$PORT"; }
    a="$(raw 'GET /select/x HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nAccept: a\r\n b\r\n\r\n')"
    b="$(raw 'GET http://evil.example.org/select/x HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n')"
    ui_teardown
    [[ "$a" == "HTTP/1.0 400 "* && "$b" == "HTTP/1.0 400 "* ]] || { echo "$a / $b"; return 1; }
}

@test "audit ui: a streamed answer goes out as it comes; one cut mid-answer is a reset, not a clean short end" {
    ui_setup; ui_start "$(id -u)" 600 600 3
    ucurl -sN "http://127.0.0.1:$PORT/stream" | while IFS= read -r l; do echo "$(date +%s.%N) $l"; done > "$T/stream.out"
    set +e; ucurl -s -o /dev/null "http://127.0.0.1:$PORT/stream-stall"; rc=$?; set -e
    ui_teardown
    first="$(sed -n 1p "$T/stream.out" | cut -d' ' -f1)" last="$(sed -n 3p "$T/stream.out" | cut -d' ' -f1)"
    [ "$(wc -l < "$T/stream.out")" = 3 ] || { cat "$T/stream.out"; return 1; }
    python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) > 1.5 else 1)' "$first" "$last" || { cat "$T/stream.out"; return 1; }
    [ "$rc" -ne 0 ] || { echo "a cut answer ended cleanly (curl 0)"; return 1; }
}

@test "audit ui: a body shorter than its Content-Length is a 400; one cut by a reset leaves no traceback" {
    ui_setup; ui_start "$(id -u)"
    short="$(printf 'POST /select/x HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nCookie: audit_ui_%s=%s\r\nContent-Length: 100\r\n\r\nhello' "$PORT" "$PORT" "$TOKEN" | python3 -c '
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1]))); s.sendall(sys.stdin.buffer.read()); s.shutdown(socket.SHUT_WR)
print(s.recv(200).split(b"\r\n")[0].decode())' "$PORT")"
    python3 -c '
import socket, struct, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(b"POST /select/x HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nContent-Length: 100\r\n\r\nhello" % sys.argv[1].encode())
time.sleep(0.3); s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)); s.close()' "$PORT"
    sleep 0.5
    ui_teardown
    [[ "$short" == "HTTP/1.0 400 "* ]] || { echo "$short"; return 1; }
    ! grep -q Traceback "$T/ui.out" || { cat "$T/ui.out"; return 1; }
}

@test "audit ui: a connection from another uid is refused and named once" {
    ui_setup; ui_start "$(( $(id -u) + 1 ))"
    c="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/" || true)"
    ucurl -s -o /dev/null "http://127.0.0.1:$PORT/" || true
    ui_teardown
    [ "$c" = 000 ] || { echo "got $c"; return 1; }
    [ "$(grep -c "refused a connection from uid $(id -u)" "$T/ui.out")" = 1 ]
}

@test "audit ui: closes by itself when idle, and at its limit even while used" {
    ui_setup; ui_start "$(id -u)" 2 600
    for _ in $(seq 50); do kill -0 "$UI" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$UI" 2>/dev/null || { ui_teardown; echo "still open"; return 1; }
    grep -q 'closed: no request for 0 minutes' "$T/ui.out" || { cat "$T/ui.out"; ui_teardown; return 1; }
    ui_start "$(id -u)" 600 3
    for _ in $(seq 60); do ucurl -s -o /dev/null "http://127.0.0.1:$PORT/" || true; kill -0 "$UI" 2>/dev/null || break; sleep 0.1; done
    ! kill -0 "$UI" 2>/dev/null || { ui_teardown; echo "still open"; return 1; }
    ui_teardown
    grep -q 'the most it stays' "$T/ui.out"
}

@test "audit ui: bad ports refused; the operator command passes only socket, port and uid" {
    for p in 80 0 65536 x; do run "$OP" audit ui --port "$p"; [ "$status" -ne 0 ] || { echo "took $p"; return 1; }; done
    printf '#!/bin/sh\necho "$@"\n' > "$T/fake-ui"; chmod +x "$T/fake-ui"
    printf '#!/bin/sh\nshift; exec "$@"\n' > "$T/bin/python3"; chmod +x "$T/bin/python3"
    AGENTS_AUDIT_UI="$T/fake-ui" run "$OP" audit ui --port 9500
    [ "$output" = "$AGENTS_AUDIT_SOCK 9500 $(id -u)" ] || { echo "$output"; return 1; }
    # agents.conf `audit on ui-uid-check off` (rendered as AGENTS_AUDIT_UI_UID_CHECK=off): uid off
    echo AGENTS_AUDIT_UI_UID_CHECK=off >> "$AIRLOCK_AGENTS_ENV"
    AGENTS_AUDIT_UI="$T/fake-ui" run "$OP" audit ui --port 9500
    [ "$output" = "$AGENTS_AUDIT_SOCK 9500 off" ] || { echo "$output"; return 1; }
    AGENTS_AUDIT_UI="$T/fake-ui" run "$OP" audit ui   # no --port: a free one each run (0)
    [ "$output" = "$AGENTS_AUDIT_SOCK 0 off" ] || { echo "$output"; return 1; }
}

@test "audit ui: the token: no cookie or a wrong token is 403; the printed URL sets the cookie and redirects without it" {
    ui_setup; ui_start "$(id -u)"
    grep -q "^the audit store's UI: http://audit.localhost:$PORT/select/vmui/?token=$TOKEN\$" "$T/ui.out" || { cat "$T/ui.out"; ui_teardown; return 1; }
    none="$(/usr/bin/curl --noproxy "*" -s -o "$T/b1" -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/")"
    bad="$(/usr/bin/curl --noproxy "*" -s -o "$T/b2" -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/?token=x$TOKEN")"
    badc="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -b "audit_ui_$PORT=x$TOKEN" "http://127.0.0.1:$PORT/select/vmui/")"
    two="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/?token=$TOKEN&token=$TOKEN")"
    hdr="$(/usr/bin/curl --noproxy "*" -s -D - -o /dev/null -H "Host: audit.localhost:$PORT" "http://127.0.0.1:$PORT/select/vmui/?q=1&token=$TOKEN")"
    # following the redirect with a cookie jar: the page itself, the token never reaches the store
    body="$(/usr/bin/curl --noproxy "*" -s -L -c "$T/jar" -b "$T/jar" "http://127.0.0.1:$PORT/select/vmui/?token=$TOKEN")"
    ui_teardown
    [ "$none" = 403 ] && [ "$bad" = 403 ] && [ "$badc" = 403 ] && [ "$two" = 403 ] || { echo "$none $bad $badc $two"; return 1; }
    ! grep -q path "$T/b1" "$T/b2" || return 1
    [[ "$hdr" == "HTTP/1.0 303 "* ]] || { echo "$hdr"; return 1; }
    grep -q $'^Location: /select/vmui/?q=1\r$' <<< "$hdr" || { echo "$hdr"; return 1; }
    grep -q "^Set-Cookie: audit_ui_$PORT=$TOKEN; Path=/; HttpOnly; SameSite=Strict"$'\r$' <<< "$hdr" || { echo "$hdr"; return 1; }
    ! grep -qi '^Set-Cookie:.*Domain' <<< "$hdr" || return 1
    grep -q $'^Referrer-Policy: no-referrer\r$' <<< "$hdr" || return 1
    [[ "$body" == *'"path": "/select/vmui/"'* ]] || { echo "$body"; return 1; }
    [[ "$body" != *"$TOKEN"* && "$body" != *Cookie* ]] || { echo "token or cookie reached the store: $body"; return 1; }
}

@test "audit ui: audit.localhost is its name; ::1 is served where the host has it (owner from tcp6)" {
    python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0))' 2>/dev/null || skip "no ::1 here"
    ui_setup; ui_start "$(id -u)"
    v4="$(ucurl -s -o /dev/null -w '%{http_code}' --resolve "audit.localhost:$PORT:127.0.0.1" "http://audit.localhost:$PORT/select/vmui/")"
    v6="$(ucurl -s -o /dev/null -w '%{http_code}' --resolve "audit.localhost:$PORT:[::1]" "http://audit.localhost:$PORT/select/vmui/")"
    ui_teardown
    [ "$v4" = 200 ] && [ "$v6" = 200 ] || { echo "$v4 $v6"; cat "$T/ui.out"; return 1; }
}

@test "audit ui: listens on loopback only: 127.0.0.1 and ::1, never a wildcard or another address" {
    ui_setup; ui_start "$(id -u)"
    l="$(python3 -c '
import sys
port = "%04X" % int(sys.argv[1])
for f in ("/proc/net/tcp", "/proc/net/tcp6"):
    for line in open(f).readlines()[1:]:
        c = line.split()
        if c[3] == "0A" and c[1].endswith(":" + port):
            print(c[1].split(":")[0])' "$PORT")"
    ui_teardown
    [ -n "$l" ] || { echo "nothing listening"; return 1; }
    while read -r a; do
        case "$a" in 0100007F|00000000000000000000000001000000) ;; *) echo "listens on $a"; return 1 ;; esac
    done <<< "$l"
}

@test "audit ui: a host without IPv6 is served on 127.0.0.1 alone" {
    ui_setup
    cat > "$T/noipv6.py" <<'PY'
import errno, runpy, socket, sys
orig = socket.socket.bind
def bind(self, addr):
    if self.family == socket.AF_INET6:
        raise OSError(errno.EADDRNOTAVAIL, "Cannot assign requested address")
    return orig(self, addr)
socket.socket.bind = bind
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
    : > "$T/ui.out"
    python3 -I "$T/noipv6.py" "$REPO/agents/lib/audit-ui" "$AGENTS_AUDIT_SOCK" 0 "$(id -u)" > "$T/ui.out" 2>&1 3>&- & UI=$!
    ui_wait
    c="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/")"
    up=0; kill -0 "$UI" 2>/dev/null && up=1
    ui_teardown
    [ "$up" = 1 ] && [ "$c" = 200 ] || { echo "up=$up code=$c"; cat "$T/ui.out"; return 1; }
    ! grep -q -i 'error\|traceback' "$T/ui.out" || { cat "$T/ui.out"; return 1; }
    # and a kernel without IPv6: the socket itself refused (EAFNOSUPPORT)
    ui_setup
    cat > "$T/noaf6.py" <<'PY'
import errno, runpy, socket, sys
class NoV6(socket.socket):
    def __init__(self, family=-1, *a, **k):
        if family == socket.AF_INET6:
            raise OSError(errno.EAFNOSUPPORT, "Address family not supported by protocol")
        super().__init__(family, *a, **k)
socket.socket = NoV6
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
PY
    : > "$T/ui.out"
    python3 -I "$T/noaf6.py" "$REPO/agents/lib/audit-ui" "$AGENTS_AUDIT_SOCK" 0 "$(id -u)" > "$T/ui.out" 2>&1 3>&- & UI=$!
    ui_wait
    c="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/")"
    ui_teardown
    [ "$c" = 200 ] || { echo "no-AF_INET6 code=$c"; cat "$T/ui.out"; return 1; }
}

@test "audit ui: with the uid check off: the token alone, a random name per run and only that Host" {
    ui_setup; ui_start off
    grep -q 'with its token alone (the uid check is off)' "$T/ui.out" || { cat "$T/ui.out"; ui_teardown; return 1; }
    n1="$NAME"
    [[ "$n1" =~ ^[0-9a-f]{20}\.audit\.localhost$ ]] || { echo "name $n1"; ui_teardown; return 1; }
    ok="$(ucurl -s -o /dev/null -w '%{http_code}' -H "Host: $n1:$PORT" "http://127.0.0.1:$PORT/select/vmui/")"
    nocookie="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -H "Host: $n1:$PORT" "http://127.0.0.1:$PORT/select/vmui/")"
    known="$(ucurl -s -o /dev/null -w '%{http_code}' -H "Host: audit.localhost:$PORT" "http://127.0.0.1:$PORT/select/vmui/")"
    ip="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/?token=$TOKEN")"
    ui_teardown
    ui_start off; n2="$NAME"; ui_teardown
    [ "$ok" = 200 ] && [ "$nocookie" = 403 ] && [ "$known" = 421 ] && [ "$ip" = 421 ] || { echo "$ok $nocookie $known $ip"; return 1; }
    [ "$n1" != "$n2" ] || { echo "same name twice: $n1"; return 1; }
    # with the check on, the same cookie from another uid is refused at the connection
    ui_start "$(( $(id -u) + 1 ))"
    on="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/" || true)"
    ui_teardown
    [ "$on" = 000 ] || { echo "on: $on"; return 1; }
}

@test "audit ui: port 0 picks a free port, the same on 127.0.0.1 and ::1, and prints it" {
    ui_setup; ui_start off
    p="$PORT"
    c="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -b "audit_ui_$p=$TOKEN" -H "Host: $NAME:$p" "http://127.0.0.1:$p/select/vmui/")"
    c6=skip
    if python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0))' 2>/dev/null; then
        c6="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -b "audit_ui_$p=$TOKEN" -H "Host: $NAME:$p" "http://[::1]:$p/select/vmui/")"
    fi
    ui_teardown
    [ -n "$p" ] && [ "$p" != 0 ] && [ "$c" = 200 ] && { [ "$c6" = 200 ] || [ "$c6" = skip ]; } || { echo "port $p code $c v6 $c6"; cat "$T/ui.out"; return 1; }
}

@test "audit ui: an odd cookie from another service doesn't hide this run's; a redirect never leaves the UI" {
    ui_setup; ui_start "$(id -u)"
    odd="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -H "Cookie: a=\"x; x[]=1; y=a\\b; audit_ui_$PORT=$TOKEN" "http://127.0.0.1:$PORT/select/vmui/")"
    loc1="$(/usr/bin/curl --noproxy "*" -s -D - -o /dev/null --path-as-is "http://127.0.0.1:$PORT/\\evil.example.org/?token=$TOKEN" | sed -n 's/^Location: //p' | tr -d '\r')"
    loc2="$(/usr/bin/curl --noproxy "*" -s -D - -o /dev/null "http://127.0.0.1:$PORT/select/vmui/?flag&q=a%26b+c&token=$TOKEN&x=%FF" | sed -n 's/^Location: //p' | tr -d '\r')"
    ui_teardown
    [ "$odd" = 200 ] || { echo "odd cookie: $odd"; return 1; }
    [ "$loc1" = "/select/vmui/" ] || { echo "loc1: $loc1"; return 1; }
    [ "$loc2" = "/select/vmui/?flag&q=a%26b+c&x=%FF" ] || { echo "loc2: $loc2"; return 1; }
}

# ---- audit events ----------------------------------------------------------------------------------
@test "events: one fixed query, the severity and above, kind and agent only in their checked shape" {
    row '{"_time":"2026-11-15T14:05:00Z","audit.severity":"high","audit.kind":"privilege","audit.agent":"agent","audit.session":"proj.main","log_type":"journal","_msg":"agent : user NOT in sudoers"}'
    row '{"_time":"2026-11-15T14:04:00Z","audit.severity":"medium","audit.kind":"envoy-refused","audit.agent":"agent","log_type":"envoy-access","envoy.method":"CONNECT","envoy.authority":"example.org:443","envoy.route":"deny-connect","envoy.status":"403"}'
    run "$OP" audit events --severity medium --kind privilege --agent agent --since 2h
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    q="$(sed -n 1p "$CALLS")"
    [[ "$q" == '_time:>='????-??-??T??:??:??Z' audit.severity:in(high,medium) audit.kind:="privilege" audit.agent:="agent" | sort by (_time desc) | limit 10000 | fields '* ]] || { echo "$q"; return 1; }
    [[ "$(sed -n 2p "$CALLS")" == *'| stats by (audit.severity) count() n' ]]
    [[ "${lines[0]}" == "2026-11-15 14:05:00  high    privilege            agent/proj.main               agent : user NOT in sudoers" ]] || { echo "$output"; return 1; }
    [[ "${lines[1]}" == *"medium  envoy-refused        agent                         CONNECT example.org:443  [deny-connect 403]" ]] || { echo "$output"; return 1; }
}

@test "events: defaults are medium and above, the last 24 h; low and info widen it" {
    run "$OP" audit events
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$(sed -n 1p "$CALLS")" == *' audit.severity:in(high,medium) | sort'* ]] || return 1
    : > "$CALLS"; run "$OP" audit events --severity info
    [[ "$(sed -n 1p "$CALLS")" == *' audit.severity:in(high,medium,low,info) | sort'* ]] || return 1
    : > "$CALLS"; run "$OP" audit events --severity high
    [[ "$(sed -n 1p "$CALLS")" == *' audit.severity:in(high) | sort'* ]]
}

@test "events: bad values are refused before any query (no quote, space or other text reaches it)" {
    for a in "--severity critical" "--kind Privilege" "--kind a\"b" "--agent x y" "--agent \"x" "--limit 0" "--since 5m" "--frob"; do
        # shellcheck disable=SC2086
        run "$OP" audit events $a
        [ "$status" -ne 0 ] || { echo "accepted: $a"; return 1; }
    done
    [ ! -s "$CALLS" ]
}

@test "events: the agents' text is cleaned; a redacted line says so; the count line" {
    row "$(printf '{"_time":"2026-11-15T14:05:00Z","audit.severity":"high","audit.kind":"agent-process","audit.agent":"agent","audit.redacted":"true","log_type":"journal","_msg":"x\\u001b]52;c;aGk=\\u0007y"}')"
    COUNT=3 run "$OP" audit events
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! printf '%s' "$output" | LC_ALL=C grep -qP '[\x00-\x08\x0b-\x1f\x7f]' || return 1
    [[ "${lines[0]}" == *"x?]52;c;aGk=?y (redacted)" ]] || { echo "$output"; return 1; }
    [[ "${lines[1]}" == "(high 3 since "* ]] || { echo "$output"; return 1; }
}

@test "events: repeats in a row are one row with their count and when the run began; --limit counts rows" {
    for s in 13:07 13:03 13:00; do
        row "{\"_time\":\"2026-11-15T19:$s.000Z\",\"audit.severity\":\"medium\",\"audit.kind\":\"store\",\"log_type\":\"journal\",\"_msg\":\"Please specify only one\"}"
    done
    row '{"_time":"2026-11-15T19:12:00Z","audit.severity":"high","audit.kind":"privilege","audit.agent":"agent","log_type":"journal","_msg":"user NOT in sudoers"}'
    row '{"_time":"2026-11-15T19:11:00Z","audit.severity":"medium","audit.kind":"store","log_type":"journal","_msg":"Please specify only one"}'
    COUNT=5 run "$OP" audit events --limit 2
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == "2026-11-15 19:13:07  medium  store                -                             Please specify only one (x3, from 2026-11-15 19:13:00)" ]] || { echo "$output"; return 1; }
    [[ "${lines[1]}" == *"high    privilege            agent                         user NOT in sudoers" ]] || { echo "$output"; return 1; }
    [ "${#lines[@]}" = 3 ] || { echo "$output"; return 1; }
    [[ "${lines[2]}" == *"newest 2 rows (4 lines) shown, --limit <n> for more"* ]] || { echo "$output"; return 1; }
}

@test "events: lines alike only in their first line (or on screen) are not collapsed" {
    row '{"_time":"2026-11-15T19:13:07Z","audit.severity":"medium","audit.kind":"agent-process","audit.agent":"agent","log_type":"journal","_msg":"ok\nfirst hidden thing"}'
    row '{"_time":"2026-11-15T19:13:06Z","audit.severity":"medium","audit.kind":"agent-process","audit.agent":"agent","log_type":"journal","_msg":"ok\nsecond hidden thing"}'
    COUNT=2 run "$OP" audit events
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${#lines[@]}" = 3 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" != *"(x2"* && "${lines[1]}" != *"(x2"* ]] || { echo "$output"; return 1; }
}

@test "events --full: each event's whole text under its row, every line cleaned and wrapped; rows alone without it" {
    row "$(printf '{"_time":"2026-11-15T20:35:15Z","audit.severity":"high","audit.kind":"privilege","audit.agent":"agent","log_type":"journal","_msg":"agent : user NOT in sudoers ; COMMAND=/usr/bin/true\\nsecond line \\u001b]52;c;aGk=\\u0007end %s"}' "$(printf 'w%.0s' $(seq 150))")"
    row '{"_time":"2026-11-15T20:35:00Z","audit.severity":"medium","audit.kind":"envoy-refused","audit.agent":"agent","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.method":"CONNECT","envoy.authority":"example.org:443","envoy.route":"deny-connect","envoy.status":"403","envoy.details":"direct_response"}'
    COUNT=2 run "$OP" audit events --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    ! printf '%s' "$output" | LC_ALL=C grep -qP '[\x00-\x08\x0b-\x1f\x7f]' || return 1
    [[ "${lines[1]}" == "      agent : user NOT in sudoers ; COMMAND=/usr/bin/true" ]] || { echo "$output"; return 1; }
    [[ "${lines[2]}" == "      second line ?]52;c;aGk=?end "* ]] || { echo "$output"; return 1; }
    for l in "${lines[@]}"; do [ "${#l}" -le 200 ] || { echo "a line over 200: $l"; return 1; }; done
    grep -qx '      listener=agent-infra method=CONNECT authority=example.org:443 route=deny-connect status=403 details=direct_response' <<< "$output" || { echo "$output"; return 1; }
    run "$OP" audit events
    [ "${#lines[@]}" = 3 ] || { echo "$output"; return 1; }
}

@test "events --full: a newline flood is cut at 40 lines; Envoy runs with other details don't collapse; wide text fits the width" {
    row "$(python3 -c 'import json; print(json.dumps({"_time":"2026-11-15T20:35:15Z","audit.severity":"high","audit.kind":"agent-process","audit.agent":"agent","log_type":"journal","_msg":"x" + "\n"*2000}))')"
    row '{"_time":"2026-11-15T20:35:01Z","audit.severity":"medium","audit.kind":"envoy-refused","audit.agent":"agent","log_type":"envoy-access","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/","envoy.route":"r","envoy.status":"503","envoy.details":"lua_response"}'
    row '{"_time":"2026-11-15T20:35:00Z","audit.severity":"medium","audit.kind":"envoy-refused","audit.agent":"agent","log_type":"envoy-access","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/","envoy.route":"r","envoy.status":"503","envoy.details":"other"}'
    row "$(python3 -c 'import json; print(json.dumps({"_time":"2026-11-15T20:34:00Z","audit.severity":"medium","audit.kind":"agent-process","audit.agent":"agent","log_type":"journal","_msg":"é"*150 + " " + "字"*150}))')"
    COUNT=4 run "$OP" audit events --full
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "$(grep -c '^      $' <<< "$output")" -le 40 ] || { echo "flood not cut"; return 1; }
    grep -qF '...[cut at 2000 characters or 40 lines]' <<< "$output" || return 1
    [ "$(grep -c 'envoy-refused' <<< "$output")" = 2 ] || { echo "$output" | grep envoy; return 1; }
    python3 -c '
import sys, unicodedata
for l in sys.stdin.read().splitlines():
    w = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in l)
    assert w <= 200, (w, l[:40])
    l.encode("utf-8")' <<< "$output" || return 1
    grep -q 'éééé' <<< "$output" && grep -q '字字字' <<< "$output"
}

# A connection that sends nothing frees its slot within seconds (the request line and headers have
# 5 s), so idle connections can't hold the cap for long; a slow answer still streams.
@test "audit ui: an idle connection is closed within seconds; with the slots full, a request gets through soon after" {
    ui_setup; ui_start off
    python3 -c '
import socket, sys, time
port = int(sys.argv[1])
held = [socket.create_connection(("127.0.0.1", port)) for _ in range(256)]
t = time.monotonic()
held[0].settimeout(15)
gone = held[0].recv(1) == b""
print("closed-after=%.1f" % (time.monotonic() - t) if gone else "still-open")' "$PORT" > "$T/idle.out"
    sleep 1
    c="$(ucurl -s -o /dev/null -w '%{http_code}' -H "Host: $NAME:$PORT" "http://127.0.0.1:$PORT/select/vmui/")"
    ui_teardown
    s="$(sed -n 's/closed-after=//p' "$T/idle.out")"
    [ -n "$s" ] && python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 10 else 1)' "$s" || { cat "$T/idle.out"; return 1; }
    [ "$c" = 200 ] || { echo "after the flood: $c"; return 1; }
}

# The header deadline is the whole request line and headers, not each read: a client that sends
# a byte every few seconds is cut at 5 s all the same.
@test "audit ui: a client trickling its headers a byte at a time is cut at the deadline" {
    ui_setup; ui_start "$(id -u)"
    r="$(python3 -c '
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
t = time.monotonic()
try:
    for b in b"GET /select/vmui/ HTTP/1.0\r\nX-Slow: " + b"a" * 30:
        s.sendall(bytes([b])); time.sleep(2)
        if time.monotonic() - t > 20: break
    print("held %.0f" % (time.monotonic() - t))
except OSError:
    print("cut %.1f" % (time.monotonic() - t))' "$PORT")"
    ui_teardown
    case "$r" in "cut "*) python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 10 else 1)' "${r#cut }" ;; *) echo "$r"; false ;; esac
}

# A request the deadline cut mid-headers is never forwarded, even with the cookie in it.
@test "audit ui: a request cut at the header deadline never reaches the store" {
    ui_setup; ui_start "$(id -u)"
    python3 -c '
import socket, sys, time
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.sendall(("GET /cutprobe HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nCookie: audit_ui_%s=%s\r\nX-Slow: " % (sys.argv[1], sys.argv[1], sys.argv[2])).encode())
try:
    for _ in range(12):
        s.sendall(b"a"); time.sleep(1)
except OSError:
    pass' "$PORT" "$TOKEN"
    ok="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/")"
    ui_teardown
    [ "$ok" = 200 ] || { echo "after: $ok"; return 1; }
    ! grep -q cutprobe "$AGENTS_AUDIT_SOCK.paths" || { echo "a cut request reached the store"; return 1; }
    grep -q '^/select/vmui/$' "$AGENTS_AUDIT_SOCK.paths"
}

# A port given (--port): the relay takes exactly it, on 127.0.0.1 and ::1, and refuses to start
# when ::1 has it taken by something else (a browser trying ::1 first would reach that).
@test "audit ui: an explicit port is used as given, and refused when ::1 has it taken" {
    ui_setup; ui_start "$(id -u)"; p="$PORT"; t1="$TOKEN"; kill "$UI"; wait "$UI" 2>/dev/null || true
    UI_PORT="$p" ui_start "$(id -u)"
    [ "$PORT" = "$p" ] || { echo "asked $p, got $PORT"; return 1; }
    c4="$(ucurl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$p/select/vmui/")"
    c6=skip
    if python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1",0))' 2>/dev/null; then
        c6="$(ucurl -s -o /dev/null -w '%{http_code}' -H "Host: audit.localhost:$p" "http://[::1]:$p/select/vmui/")"
        kill "$UI"; wait "$UI" 2>/dev/null || true; UI=
        # something else on [::1]:p (SO_REUSEADDR: the port's earlier connections may sit in TIME_WAIT)
        python3 -c '
import socket, sys, time
s = socket.socket(socket.AF_INET6)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
s.bind(("::1", int(sys.argv[1]))); s.listen()
open(sys.argv[2], "w").close()
time.sleep(30)' "$p" "$T/held.ready" > "$T/hold.out" 2>&1 3>&- & HOLD=$!
        for _ in $(seq 50); do [ -e "$T/held.ready" ] && break; sleep 0.1; done
        [ -e "$T/held.ready" ] || { echo "couldn't hold [::1]:$p"; cat "$T/hold.out"; kill "$HOLD" 2>/dev/null; return 1; }
        set +e; timeout 10 python3 -I "$REPO/agents/lib/audit-ui" "$AGENTS_AUDIT_SOCK" "$p" "$(id -u)" > "$T/held.out" 2>&1 3>&-; rc=$?; set -e
        kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null || true
        [ "$rc" = 1 ] && grep -q "can't listen on \[::1\]:$p" "$T/held.out" || { echo "rc=$rc"; cat "$T/held.out"; return 1; }
    fi
    ui_teardown
    [ "$t1" != "$TOKEN" ] && [ "$c4" = 200 ] && { [ "$c6" = 200 ] || [ "$c6" = skip ]; } || { echo "$c4 $c6"; return 1; }
}
