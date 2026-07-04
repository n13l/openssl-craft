#!/bin/bash
#
# repro-issue-11197.sh
#
# Diagnose TLS 1.3 0-RTT / ALPN session-ticket behaviour, reproducing the
# workflow from https://github.com/openssl/openssl/issues/11197
# ("tls_construct_new_session_ticket does not always update ALPN correctly").
#
#   1. Connect, negotiate ALPN, save the session               (sess1)
#   2. Resume sess1 WITHOUT ALPN, save the new session          (sess2)
#   3. Resume sess2 WITH ALPN and attempt 0-RTT early data
#
# sess2 is minted by a handshake that negotiated NO ALPN, so its ticket must
# carry no ALPN. Step 3 then offers ALPN again:
#
#   * BUG present  -> ticket wrongly kept the stale ALPN -> server ACCEPTS 0-RTT
#   * fixed        -> ticket ALPN cleared -> ALPN mismatch -> server REJECTS 0-RTT
#
# The script prints, in plain text, whether 0-RTT early data was ACCEPTED or
# REJECTED, as seen by both the client and the server.
#
# Usage:
#   ./repro-issue-11197.sh                # use ./apps/openssl from this tree
#   OPENSSL=/path/to/openssl ./repro-issue-11197.sh
#   PORT=45000 ALPN=h2 ./repro-issue-11197.sh
#
# Exit status: 0 if the 0-RTT verdict was determined, 1 on setup failure.

set -u

# --- configuration -----------------------------------------------------------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST="${HOST:-127.0.0.1}"          # force IPv4 to avoid ::1/0.0.0.0 mismatch
PORT="${PORT:-44400}"
ALPN="${ALPN:-myalpn}"
CERT="${CERT:-$HERE/apps/server.pem}"
KEY="${KEY:-$HERE/apps/server.pem}"

# Locate the openssl binary. Prefer $OPENSSL, then the in-tree build (with its
# libraries via LD_LIBRARY_PATH), then whatever is on $PATH.
if [ -n "${OPENSSL:-}" ]; then
    OSSL="$OPENSSL"
elif [ -x "$HERE/apps/openssl" ]; then
    OSSL="$HERE/apps/openssl"
    export LD_LIBRARY_PATH="$HERE${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
else
    OSSL="openssl"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repro11197.XXXXXX")"
cleanup() {
    [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
    pkill -f "s_server -accept $HOST:$PORT" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- helpers -----------------------------------------------------------------
say() { printf '%s\n' "$*"; }
rule() { printf -- '------------------------------------------------------------\n'; }

wait_for_server() {  # wait until s_server logs that it is listening
    # NB: do NOT probe with a real TCP connection here - that would consume one
    # of the server's -naccept slots and it would exit before our last client.
    local i
    for i in $(seq 1 50); do
        grep -qa "ACCEPT" "$WORK/server.log" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

# status line summarising a client log: session (new/reused) + ALPN
client_summary() {  # $1 = log file
    local f="$1" sess alpn
    if grep -qa "Reused, TLS" "$f"; then sess="reused"
    elif grep -qa "New, TLS" "$f"; then sess="new"
    else sess="??"; fi
    alpn="$(grep -a "ALPN protocol:" "$f" | head -1 | sed 's/.*ALPN protocol: *//')"
    [ -z "$alpn" ] && alpn="(none)"
    printf 'session=%-7s ALPN=%s' "$sess" "$alpn"
}

# --- banner ------------------------------------------------------------------
say "==== TLS 1.3 0-RTT / ALPN ticket diagnosis (issue #11197) ===="
say "openssl : $OSSL"
say "version : $("$OSSL" version 2>/dev/null)"
say "endpoint: $HOST:$PORT   ALPN='$ALPN'"
rule

# --- server ------------------------------------------------------------------
# Keep the server's stdin open (sleep) so it stays in the accept/echo loop long
# enough to flush NewSessionTickets and to live across all three connections.
pkill -f "s_server -accept $HOST:$PORT" 2>/dev/null; sleep 1
printf 'helloworld early data\n' > "$WORK/early.txt"

( sleep 60 ) | "$OSSL" s_server -accept "$HOST:$PORT" -naccept 3 \
    -cert "$CERT" -key "$KEY" -tls1_3 -early_data -alpn "$ALPN" \
    > "$WORK/server.log" 2>&1 &
SRV=$!

if ! wait_for_server; then
    say "ERROR: server did not start listening on $HOST:$PORT"
    say "--- server.log ---"; cat "$WORK/server.log"
    exit 1
fi

# --- client helper -----------------------------------------------------------
# Exchange a byte and linger so the post-handshake NewSessionTicket is received
# and saved (s_client writes -sess_out from its new_session callback).
client() {  # $1 = logfile ; rest = extra s_client args
    local log="$1"; shift
    ( printf 'ping\n'; sleep 3 ) | "$OSSL" s_client -connect "$HOST:$PORT" \
        -tls1_3 -verify_quiet "$@" > "$log" 2>&1
}

say "running 3 sequential connections (~15s; each lingers to collect its ticket)"
rule

# Step 1: fresh connection, negotiate ALPN, save sess1
client "$WORK/c1.log" -alpn "$ALPN" -sess_out "$WORK/sess1.pem"
say "step 1  new handshake        : $(client_summary "$WORK/c1.log")   [sess1 $( [ -s "$WORK/sess1.pem" ] && echo saved || echo MISSING)]"

# Step 2: resume sess1 WITHOUT ALPN, save sess2
client "$WORK/c2.log" -sess_in "$WORK/sess1.pem" -sess_out "$WORK/sess2.pem"
say "step 2  resume, drop ALPN    : $(client_summary "$WORK/c2.log")   [sess2 $( [ -s "$WORK/sess2.pem" ] && echo saved || echo MISSING)]"

# Need sess2 to attempt 0-RTT in step 3.
if [ ! -s "$WORK/sess1.pem" ] || [ ! -s "$WORK/sess2.pem" ]; then
    say ""
    say "ERROR: session tickets were not captured (sess1/sess2 missing);"
    say "cannot attempt 0-RTT. Re-run with KEEP=1 and inspect the logs."
    say "--- c1.log tail ---"; tail -15 "$WORK/c1.log"
    exit 1
fi

# Step 3: resume sess2 WITH ALPN and attempt 0-RTT early data
( sleep 3 ) | "$OSSL" s_client -connect "$HOST:$PORT" -tls1_3 -verify_quiet \
    -sess_in "$WORK/sess2.pem" -alpn "$ALPN" -early_data "$WORK/early.txt" \
    > "$WORK/c3.log" 2>&1
say "step 3  resume + ALPN + 0RTT : $(client_summary "$WORK/c3.log")"

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=
rule

# --- 0-RTT verdict -----------------------------------------------------------
CLIENT_ED="$(grep -aoE 'Early data was (accepted|rejected|not sent)' "$WORK/c3.log" | head -1)"
if grep -qa "Early data was rejected" "$WORK/server.log"; then
    SERVER_ED="Early data was rejected"
elif grep -qa "Early data received:" "$WORK/server.log"; then
    SERVER_ED="Early data received (accepted)"
else
    SERVER_ED="(no early-data verdict logged)"
fi

case "$CLIENT_ED" in
    *accepted*) VERDICT="ACCEPTED" ;;
    *rejected*) VERDICT="REJECTED" ;;
    *)          VERDICT="UNKNOWN" ;;
esac

say ">>> 0-RTT EARLY DATA (step 3): $VERDICT"
say "      client reports: ${CLIENT_ED:-<none>}"
say "      server reports: $SERVER_ED"
rule
case "$VERDICT" in
  ACCEPTED)
    say "Interpretation: 0-RTT was ACCEPTED even though sess2 was minted by a"
    say "handshake that negotiated NO ALPN => the ticket retained a stale ALPN."
    say "This is the BUG of issue #11197 (fix NOT present)." ;;
  REJECTED)
    say "Interpretation: 0-RTT was REJECTED because sess2's ticket carries no"
    say "ALPN, so the re-offered ALPN mismatches => correct behaviour."
    say "The #11197 fix IS present (handshake still completed as 1-RTT resume)." ;;
  *)
    say "Interpretation: could not determine the 0-RTT verdict; inspect logs in"
    say "a copy of the work dir (re-run with KEEP=1 to preserve them)." ;;
esac

# Optionally preserve logs for inspection.
if [ -n "${KEEP:-}" ]; then
    dest="./repro11197-logs"
    mkdir -p "$dest" && cp "$WORK"/*.log "$WORK"/*.pem "$dest"/ 2>/dev/null
    say ""
    say "logs preserved in: $dest"
    trap - EXIT; kill "${SRV:-0}" 2>/dev/null; rm -rf "$WORK"
fi

[ "$VERDICT" = "UNKNOWN" ] && exit 1 || exit 0
