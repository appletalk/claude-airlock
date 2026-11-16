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
    *envoy.method:CONNECT*) cat "$(dirname "$CALLS")/connects" 2>/dev/null ;;
    *) cat "$(dirname "$CALLS")/rows" ;;
esac
printf '\n200'
EOF
    chmod +x "$T/bin/curl"
    export PATH="$T/bin:$PATH"
    : > "$T/rows"; : > "$T/connects"
}
row() { printf '%s\n' "$1" >> "$T/rows"; }
denies() { run "$OP" audit denies "$@"; }

@test "the query is fixed: Envoy's own refusals since the window, newest first, limited" {
    denies --since 2h --limit 7
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    q="$(sed -n 1p "$CALLS")"
    pred='log_type:in("envoy-access","envoy-web") (envoy.flags:NR or envoy.flags:UAEX or envoy.details:~"^rbac_access_denied" or envoy.route:~"^deny-" or (log_type:envoy-web envoy.flags:~"UF|DF") or (envoy.status:>=400 -envoy.details:via_upstream -envoy.details:~"^(upstream_|no_healthy_upstream)" -envoy.details:~"timeout"))'
    [[ "$q" == '_time:>='????-??-??T??:??:??Z" $pred | sort by (_time desc) | limit 7 | fields "* ]] || { echo "$q"; return 1; }
    [[ "$(sed -n 2p "$CALLS")" == *'| stats count() n' ]]
    [[ "$output" == *"(no refusals since "* ]]
}

@test "a refused CONNECT, a preset's refusal and a locked credential: who, what, route, the site file line" {
    row '{"_time":"2026-11-15T14:02:11.5Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"12","envoy.method":"CONNECT","envoy.authority":"example.org:443","envoy.path":"","envoy.route":"deny-connect","envoy.status":"403","envoy.flags":"-","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:01:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"11","envoy.method":"POST","envoy.authority":"git.example.org","envoy.path":"/api/v1/repos/a/b/merge","envoy.route":"git.example.org-refused","envoy.status":"403","envoy.flags":"-","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:00:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.method":"GET","envoy.authority":"git.example.org","envoy.path":"/","envoy.route":"git.example.org-read","envoy.status":"423","envoy.details":"lua_response"}'
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == "2026-11-15 14:02:11  agent            agent-infra              403  CONNECT example.org:443  [deny-connect]" ]]
    [[ "${lines[1]}" == "    example.org:443 is not a destination of agent-infra: add it to the agent-infra lines" ]]
    [[ "${lines[2]}" == *"POST git.example.org/api/v1/repos/a/b/merge  [git.example.org-refused]" ]]
    [[ "${lines[3]}" == *"refused by the rules of git.example.org: its http line"* ]]
    [[ "${lines[5]}" == *"locked: airlock-envoy-cred unlock" ]]
    [[ "${lines[6]}" == "(3 refusals since "*"; the site file: /etc/airlock-envoy/site.conf)" ]]
}

@test "a refused TLS name gets its user from the latest CONNECT before it with that connection id" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"sni-x","envoy.connection":"40","envoy.sni":"other.example.org","envoy.route":"","envoy.flags":"NR"}'
    # the same id twice (Envoy restarted): the later one, still before the SNI line, wins; one after it doesn't
    printf '%s\n' \
        '{"_time":"2026-11-14T10:00:00Z","envoy.connection":"40","envoy.user":"old","envoy.listener":"old-l","envoy.authority":"old.example.org:443"}' \
        '{"_time":"2026-11-15T14:04:59Z","envoy.connection":"40","envoy.user":"agent","envoy.listener":"agent-infra","envoy.authority":"svc.example.org:443"}' \
        '{"_time":"2026-11-15T14:09:00Z","envoy.connection":"40","envoy.user":"later","envoy.listener":"later-l","envoy.authority":"later.example.org:443"}' > "$T/connects"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"agent            agent-infra                -  TLS other.example.org in a tunnel to svc.example.org:443  [no route NR]" ]]
    [[ "${lines[1]}" == "    the tunnel to svc.example.org:443 sent the TLS name other.example.org: only svc.example.org passes" ]]
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == *'envoy.connection:in(40) '* ]]
}

@test "the join takes only a CONNECT from 20 s before to 1 s after: an older tunnel with the same id is not a guess" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"40","envoy.sni":"other.example.org","envoy.flags":"NR"}'
    printf '%s\n' '{"_time":"2026-11-15T14:04:30Z","envoy.connection":"40","envoy.user":"agent2","envoy.listener":"agent2-l","envoy.authority":"x.example.org:443"}' > "$T/connects"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"  ?                ?                          -  TLS other.example.org in a tunnel to ?  "* ]] || { echo "$output"; return 1; }
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == '_time:[2026-11-15T14:04:40Z, 2026-11-15T14:05:02Z] '*'| sort by (_time desc) | limit 10000 '* ]] || { echo "$q"; return 1; }
}

@test "an HTTP line without a method (the parser refused it) is not taken for a TLS refusal or joined" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"agent-infra","envoy.user":"agent","envoy.connection":"7","envoy.status":"400","envoy.details":"http1.codec_error"}'
    printf '%s\n' '{"_time":"2026-11-15T14:04:59Z","envoy.connection":"7","envoy.user":"other","envoy.listener":"other-l","envoy.authority":"old.example.org:443"}' > "$T/connects"
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"agent            agent-infra              400  (a request Envoy could not read) "* ]] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    Envoy refused the request itself (http1.codec_error)" ]
    ! grep -q CONNECT "$CALLS" || return 1
}

@test "hints by what Envoy did: no token, a body too large, a protected branch, the push check failing, web unreachable" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/","envoy.route":"a.example.org-read","envoy.status":"503","envoy.details":"lua_response"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"m.example.org","envoy.path":"/mcp","envoy.route":"m.example.org-ep0-post-too-large","envoy.status":"413","envoy.details":"direct_response"}'
    row '{"_time":"2026-11-15T14:03:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"g.example.org","envoy.path":"/o/r/git-receive-pack","envoy.route":"g.example.org-push-guard","envoy.status":"200","envoy.flags":"UAEX","envoy.details":"ext_authz_denied"}'
    row '{"_time":"2026-11-15T14:02:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"POST","envoy.authority":"g.example.org","envoy.path":"/o/r/git-receive-pack","envoy.route":"g.example.org-push-guard","envoy.status":"503","envoy.details":"ext_authz_error"}'
    row '{"_time":"2026-11-15T14:01:00Z","log_type":"envoy-web","envoy.listener":"w","envoy.user":"agent","envoy.sni":"n.example.org","envoy.route":"web","envoy.flags":"UF"}'
    row '{"_time":"2026-11-15T14:00:00Z","log_type":"envoy-access","envoy.listener":"l","envoy.user":"agent","envoy.method":"GET","envoy.authority":"a.example.org","envoy.path":"/x_y","envoy.route":"a.example.org-read","envoy.status":"400","envoy.details":"http1.unexpected_underscore"}'
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ "${lines[1]}" = "    the credential for a.example.org has no token (airlock-envoy-cred)" ] || { echo "$output"; return 1; }
    [ "${lines[3]}" = "    a body over the limit of the rules of m.example.org (its http line)" ]
    [ "${lines[5]}" = "    a push to a protected branch of g.example.org: protect on its http line" ]
    [ "${lines[7]}" = "    the push check for g.example.org could not decide, so the push was refused (it fails closed)" ]
    [ "${lines[9]}" = "    web could not connect to n.example.org (down, or an internal address its kernel filter refuses)" ]
    [ "${lines[11]}" = "    Envoy refused the request itself (http1.unexpected_underscore)" ]
}

@test "an SNI line with no CONNECT to join shows no user rather than a guess; a bad id is never queried" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-access","envoy.connection":"41","envoy.sni":"x.example.org","envoy.flags":"NR"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.connection":"1) or (x","envoy.sni":"y.example.org","envoy.flags":"NR"}'
    denies
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[0]}" == *"  ?                ?                          -  TLS x.example.org in a tunnel to ?  "* ]]
    q="$(grep CONNECT "$CALLS")"
    [[ "$q" == *'envoy.connection:in(41) '* && "$q" != *"or (x"* ]]
}

@test "web's internal-name refusal, an address entry's RBAC refusal" {
    row '{"_time":"2026-11-15T14:05:00Z","log_type":"envoy-web","envoy.listener":"agent-web","envoy.user":"agent","envoy.sni":"metrics.example.org","envoy.route":"deny-internal-name"}'
    row '{"_time":"2026-11-15T14:04:00Z","log_type":"envoy-access","envoy.connection":"5","envoy.sni":"one.example.org","envoy.route":"tls-no-sni","envoy.details":"rbac_access_denied_matched_policy[server-name-sent]"}'
    printf '%s\n' '{"_time":"2026-11-15T14:03:55Z","envoy.connection":"5","envoy.user":"agent","envoy.listener":"agent-infra","envoy.authority":"10.99.0.1:6443"}' > "$T/connects"
    denies
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
    COUNT=312 denies --limit 1
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "${lines[2]}" == "(1 of 312 refusals since "*", newest first: --limit <n> for more)" ]]
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
    run "$OP" audit; [ "$status" -ne 0 ]; [[ "$output" == *"usage: agent audit denies"* ]]
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
import http.server, json, os, socket, socketserver, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        b = json.dumps({"path": self.path, "headers": dict(self.headers)}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(b)))
        self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Access-Control-Allow-Headers", "*")
        self.end_headers(); self.wfile.write(b)
    do_POST = do_GET
class S(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    def get_request(self):
        r, _ = super().get_request(); return r, ("local", 0)
S(sys.argv[1], H).serve_forever()
PY
    python3 "$T/store.py" "$AGENTS_AUDIT_SOCK" & STORE=$!
    PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    for _ in $(seq 50); do [ -S "$AGENTS_AUDIT_SOCK" ] && break; sleep 0.1; done
}
ui_start() {  # ui_start <uid> [idle most]
    python3 -I "$REPO/agents/lib/audit-ui" "$AGENTS_AUDIT_SOCK" "$PORT" "$@" > "$T/ui.out" 2>&1 & UI=$!
    for _ in $(seq 50); do grep -q 'audit store' "$T/ui.out" 2>/dev/null && return 0; sleep 0.1; done
    cat "$T/ui.out"; return 1
}
ui_teardown() { kill "$UI" "$STORE" 2>/dev/null || true; wait 2>/dev/null || true; }

@test "audit ui: serves its own uid under its own Host, forwards only the listed headers" {
    ui_setup; ui_start "$(id -u)"
    r="$(/usr/bin/curl --noproxy "*" -s -H 'Cookie: s=1' -H 'X-Forwarded-For: 1.2.3.4' "http://127.0.0.1:$PORT/select/vmui/?q=1")"
    ui_teardown
    [[ "$r" == *'"path": "/select/vmui/?q=1"'* ]] || { echo "$r"; return 1; }
    [[ "$r" != *Cookie* && "$r" != *X-Forwarded* && "$r" == *'"Host": "x"'* ]]
}

@test "audit ui: another Host (a rebound name) gets 421, nothing reaches the store" {
    ui_setup; ui_start "$(id -u)"
    c="$(/usr/bin/curl --noproxy "*" -s -o "$T/body" -w '%{http_code}' -H 'Host: evil.example.org' "http://127.0.0.1:$PORT/select/vmui/")"
    c2="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/select/vmui/")"
    ui_teardown
    [ "$c" = 421 ] && [ "$c2" = 200 ] || { echo "$c $c2"; return 1; }
    ! grep -q path "$T/body" || return 1
}

@test "audit ui: no other site: a foreign Origin or a cross-site fetch is 403, no CORS header ever goes out, no preflight" {
    ui_setup; ui_start "$(id -u)"
    u="http://127.0.0.1:$PORT/select/logsql/query?query=*"
    o="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -H 'Origin: https://evil.example.org' "$u")"
    f="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -H 'Sec-Fetch-Site: cross-site' "$u")"
    n="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -H 'Origin: null' "$u")"
    s="$(/usr/bin/curl --noproxy "*" -s -D - -o /dev/null -H "Origin: http://127.0.0.1:$PORT" -H 'Sec-Fetch-Site: same-origin' "$u")"
    p="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' -X OPTIONS -H "Origin: https://evil.example.org" "$u")"
    ui_teardown
    [ "$o" = 403 ] && [ "$f" = 403 ] && [ "$n" = 403 ] || { echo "$o $f $n"; return 1; }
    [[ "$s" == "HTTP/1.0 200 "* ]] || { echo "$s"; return 1; }
    ! grep -qi '^access-control-' <<< "$s" || return 1
    grep -q $'^Server: audit-ui\r$' <<< "$s"
    [[ "$p" == 4* || "$p" == 5* ]] && [ "$p" != 200 ]
}

@test "audit ui: a request it serves counts as use: idle 2 s, a request every 0.5 s for 4 s keeps it open" {
    ui_setup; ui_start "$(id -u)" 2 600
    for _ in 1 2 3 4 5 6 7 8; do /usr/bin/curl --noproxy "*" -s -o /dev/null "http://127.0.0.1:$PORT/select/vmui/" || true; sleep 0.5; done
    open=0; kill -0 "$UI" 2>/dev/null && open=1
    ui_teardown
    [ "$open" = 1 ] || { cat "$T/ui.out"; return 1; }
}

@test "audit ui: refused requests don't hold off the idle limit; a control byte is a 400, no traceback" {
    ui_setup; ui_start "$(id -u)" 2 600
    c="$(printf 'GET /select/a\001b HTTP/1.0\r\nHost: 127.0.0.1:%s\r\n\r\n' "$PORT" | python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1]))); s.sendall(sys.stdin.buffer.read()); print(s.recv(100).split(b"\r\n")[0].decode())' "$PORT")"
    for _ in 1 2 3 4 5 6; do /usr/bin/curl --noproxy "*" -s -o /dev/null -H 'Host: evil.example.org' "http://127.0.0.1:$PORT/" || true; sleep 0.5; done
    gone=1; kill -0 "$UI" 2>/dev/null && gone=0
    ui_teardown
    [[ "$c" == "HTTP/1.0 400 "* ]] || { echo "$c"; return 1; }
    [ "$gone" = 1 ] || { echo "still open after 3 s of refused requests with idle 2 s"; return 1; }
    ! grep -q Traceback "$T/ui.out" || { cat "$T/ui.out"; return 1; }
}

@test "audit ui: a connection from another uid is refused and named once" {
    ui_setup; ui_start "$(( $(id -u) + 1 ))"
    c="$(/usr/bin/curl --noproxy "*" -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/select/vmui/" || true)"
    /usr/bin/curl --noproxy "*" -s -o /dev/null "http://127.0.0.1:$PORT/" || true
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
    for _ in $(seq 60); do /usr/bin/curl --noproxy "*" -s -o /dev/null "http://127.0.0.1:$PORT/" || true; kill -0 "$UI" 2>/dev/null || break; sleep 0.1; done
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
}
