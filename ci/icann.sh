#! /bin/sh
# Live checks for the icann profile (no TLS, no Handshake node).
#
# Mode selection is COMPOSE_PROFILES=icann, which replaces the handshake
# value in .env. The same selection is `docker compose --profile icann`.
#
# The stack must already be up. If a container has exited or is
# unhealthy, this prints `docker compose ps` and `docker compose logs`
# and exits at once.

set -eu

# Documented in README.md. Overrides COMPOSE_PROFILES=handshake in .env.
export COMPOSE_PROFILES=icann

DNS_HOST=${DNS_HOST:-127.0.0.1}
DNS_PORT=${DNS_PORT:-53}
DOH_URL=${DOH_URL:-http://127.0.0.1:8080/dns/api/v1.0/resolv?name=com&type=SOA}
METRICS_URL=${METRICS_URL:-http://127.0.0.1:9167/metrics}
# Wall-clock bound for the root zone to load and answer com SOA.
WAIT_SECONDS=${WAIT_SECONDS:-240}
DIG_TIME=${DIG_TIME:-5}

passed=0
failed=0
skipped=0

pass() {
	passed=$((passed + 1))
	printf 'PASS  %s\n' "$*"
}

fail() {
	failed=$((failed + 1))
	printf 'FAIL  %s\n' "$*"
}

skip() {
	skipped=$((skipped + 1))
	printf 'SKIP  %s\n' "$*"
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1
	then
		printf 'ERROR  required command not found: %s\n' "$1" >&2
		exit 2
	fi
}

dump_compose() {
	printf '\n--- docker compose ps ---\n' >&2
	docker compose ps -a >&2 || true
	printf '\n--- docker compose logs ---\n' >&2
	docker compose logs >&2 || true
}

fail_fast() {
	printf 'FAIL  %s\n' "$*" >&2
	dump_compose
	exit 1
}

# Exit at once when a container has stopped, is restarting, or is unhealthy.
require_container() {
	name=$1
	status=$(docker inspect -f '{{.State.Status}}' "${name}" 2>/dev/null) || fail_fast "${name} is not present"
	case "${status}" in
	running) ;;
	*) fail_fast "${name} has status ${status}" ;;
	esac
	health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "${name}" 2>/dev/null) || health=
	if test "${health}" = "unhealthy"
	then
		fail_fast "${name} is unhealthy"
	fi
	restarts=$(docker inspect -f '{{.RestartCount}}' "${name}" 2>/dev/null) || restarts=0
	if test "${restarts}" -gt 0
	then
		fail_fast "${name} has exited (restart count ${restarts})"
	fi
}

require_stack() {
	if docker inspect handshake-full-node >/dev/null 2>&1 \
		|| docker inspect handshake-volume-resolver >/dev/null 2>&1 \
		|| docker inspect ethereum-dns-gateway >/dev/null 2>&1 \
		|| docker inspect easy-nginx >/dev/null 2>&1
	then
		fail_fast "a service outside the icann profile is present"
	fi
	require_container is-this-you-icann-resolver
	require_container json-doh-proxy
}

dig_query() {
	dig @"${DNS_HOST}" -p "${DNS_PORT}" \
		+time="${DIG_TIME}" +tries=1 \
		+rec +notcp +noadflag \
		+nocmd +nostats \
		"$@"
}

dig_header_status() {
	printf '%s\n' "$1" | awk '
		/status:/ {
			if (match($0, /status:[[:space:]]*[A-Z]+/)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/status:[[:space:]]*/, "", s)
				print s
				exit
			}
		}
	'
}

dig_count_field() {
	label=$1
	text=$2
	printf '%s\n' "${text}" | awk -v lab="${label}" '
		{
			pat = lab ":[[:space:]]*[0-9]+"
			if (match($0, pat)) {
				s = substr($0, RSTART, RLENGTH)
				sub(/.*:[[:space:]]*/, "", s)
				print s
				exit
			}
		}
	'
}

section_has_type() {
	text=$1
	section=$2
	type=$3
	printf '%s\n' "${text}" | awk -v sec="${section}" -v typ="${type}" '
		BEGIN { insec = 0; found = 1 }
		$0 ~ (";; " sec " SECTION:") { insec = 1; next }
		/^;;/ { if (insec) insec = 0 }
		insec && $4 == typ { found = 0; exit }
		END { exit found }
	'
}

# Reference view of a deliberately broken DNSSEC zone.
# Prints live, vanished, or noref.
ref_dig() {
	dig @"$1" "$2" A +time=3 +tries=1 +rec +notcp +nocmd +nostats
}

zone_reference() {
	name=$1
	saw_nx=0
	saw_live=0
	srv=
	for srv in 1.1.1.1 8.8.8.8 9.9.9.9
	do
		ref=
		ref=$(ref_dig "${srv}" "${name}" 2>&1) || true
		rst=$(dig_header_status "${ref}")
		case "${rst}" in
		NXDOMAIN)
			saw_nx=1
			;;
		"")
			;;
		*)
			saw_live=1
			;;
		esac
	done
	if test "${saw_live}" = 1
	then
		printf '%s\n' live
	elif test "${saw_nx}" = 1
	then
		printf '%s\n' vanished
	else
		printf '%s\n' noref
	fi
}

http_get() {
	# Prints the body, then a line "HTTP <code>". Empty on a transport error.
	url=$1
	raw=$(curl -sS --max-time 10 -w '\nHTTP %{http_code}\n' "${url}" 2>/dev/null) || {
		printf '\n'
		return 1
	}
	printf '%s\n' "${raw}"
}

doh_is_soa() {
	body=$1
	printf '%s\n' "${body}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
try:
    doc = json.loads(raw)
except json.JSONDecodeError:
    sys.stderr.write("response is not JSON\n")
    sys.exit(1)
status = doc.get("Status")
answers = doc.get("Answer") or []
soa = [a for a in answers if a.get("typename") == "SOA" or a.get("type") == 6]
if status != 0 or not soa:
    sys.stderr.write("Status=%r answers=%d\n" % (status, len(answers)))
    sys.exit(1)
'
}

# ---------------------------------------------------------------------------
need_cmd dig
need_cmd curl
need_cmd awk
need_cmd python3
need_cmd docker

require_stack

printf 'Waiting up to %ss for rd=1 com SOA at %s:%s\n' "${WAIT_SECONDS}" "${DNS_HOST}" "${DNS_PORT}"
start=$(date +%s)
deadline=$((start + WAIT_SECONDS))
ready=0
next_report=${start}
while true
do
	now=$(date +%s)
	if test "${now}" -ge "${deadline}"
	then
		break
	fi
	require_stack
	out=$(dig_query +nodnssec com SOA 2>&1) || true
	st=$(dig_header_status "${out}")
	ans=$(dig_count_field ANSWER "${out}")
	if test "${st}" = "NOERROR" && test "${ans:-0}" -ge 1
	then
		ready=1
		break
	fi
	if test "${now}" -ge "${next_report}"
	then
		hint=$(printf '%s\n' "${out}" | awk '/communications error/ { sub(/^;; /, ""); print; exit }')
		if test -n "${hint}"
		then
			printf '  still waiting (%ss) status=%s (%s)\n' "$((now - start))" "${st:-none}" "${hint}"
		else
			printf '  still waiting (%ss) status=%s\n' "$((now - start))" "${st:-none}"
		fi
		next_report=$((now + 15))
	fi
	sleep 2
done

if test "${ready}" != 1
then
	printf 'FAIL  rd=1 com SOA was not NOERROR within %ss\n' "${WAIT_SECONDS}" >&2
	dump_compose
	exit 1
fi
waited=$(( $(date +%s) - start ))
pass "rd=1 com SOA is NOERROR (front end answered after ${waited}s)"

require_stack
out=$(dig_query +dnssec com SOA 2>&1) || true
st=$(dig_header_status "${out}")
if test "${st}" != "NOERROR"
then
	fail "rd=1 com SOA +dnssec expected NOERROR, got status=${st:-none}"
	printf '%s\n' "${out}" | sed 's/^/  /'
elif section_has_type "${out}" ANSWER RRSIG
then
	pass "rd=1 com SOA +dnssec has an RRSIG in the answer"
else
	fail "rd=1 com SOA +dnssec expected an RRSIG in the answer"
	printf '%s\n' "${out}" | sed 's/^/  /'
fi

# dnssec-failed.org and rhybar.cz are deliberately broken DNSSEC zones.
# A validating resolver returns SERVFAIL. Pass when either does. Skip a
# zone that has vanished, so one disappearance does not fail the run.
servfail_n=0
tested_n=0
zone=
for zone in dnssec-failed.org rhybar.cz
do
	require_stack
	ref=$(zone_reference "${zone}")
	case "${ref}" in
	vanished)
		skip "rd=1 ${zone} A (zone has vanished)"
		continue
		;;
	esac
	tested_n=$((tested_n + 1))
	out=$(dig_query +nodnssec "${zone}" A 2>&1) || true
	st=$(dig_header_status "${out}")
	if test "${st}" = "SERVFAIL"
	then
		pass "rd=1 ${zone} A is SERVFAIL"
		servfail_n=$((servfail_n + 1))
	else
		printf 'NOTE  rd=1 %s A status=%s (reference=%s)\n' "${zone}" "${st:-none}" "${ref}"
		printf '%s\n' "${out}" | sed 's/^/  /'
	fi
done
if test "${servfail_n}" -ge 1
then
	pass "at least one of dnssec-failed.org and rhybar.cz returned SERVFAIL"
elif test "${tested_n}" -eq 0
then
	skip "broken DNSSEC zones (neither zone is published)"
else
	fail "neither dnssec-failed.org nor rhybar.cz returned SERVFAIL"
fi

# DNS-over-HTTPS through json-doh-proxy (host port 8080).
doh_deadline=$(( $(date +%s) + 30 ))
doh_ok=0
doh_body=
while true
do
	require_stack
	raw=$(http_get "${DOH_URL}" || true)
	code=$(printf '%s\n' "${raw}" | awk '/^HTTP / { c = $2 } END { print c }')
	doh_body=$(printf '%s\n' "${raw}" | sed '/^HTTP /d')
	if test "${code}" = "200" && doh_is_soa "${doh_body}"
	then
		doh_ok=1
		break
	fi
	now=$(date +%s)
	if test "${now}" -ge "${doh_deadline}"
	then
		break
	fi
	sleep 2
done
if test "${doh_ok}" = 1
then
	pass "DoH com SOA via json-doh-proxy is a NOERROR answer"
else
	fail "DoH com SOA via json-doh-proxy did not return a valid answer (HTTP ${code:-none})"
	printf '%s\n' "${doh_body}" | sed 's/^/  /'
fi

# Unbound Prometheus exporter, published on loopback.
metrics_deadline=$(( $(date +%s) + 20 ))
metrics_ok=0
metrics_body=
while true
do
	require_stack
	raw=$(http_get "${METRICS_URL}" || true)
	code=$(printf '%s\n' "${raw}" | awk '/^HTTP / { c = $2 } END { print c }')
	metrics_body=$(printf '%s\n' "${raw}" | sed '/^HTTP /d')
	if test "${code}" = "200" \
		&& printf '%s\n' "${metrics_body}" | grep -q '^# TYPE ' \
		&& printf '%s\n' "${metrics_body}" | grep -q '^unbound_'
	then
		metrics_ok=1
		break
	fi
	now=$(date +%s)
	if test "${now}" -ge "${metrics_deadline}"
	then
		break
	fi
	sleep 2
done
if test "${metrics_ok}" = 1
then
	pass "Prometheus metrics on ${METRICS_URL}"
else
	fail "metrics on ${METRICS_URL} did not serve Prometheus unbound_ metrics (HTTP ${code:-none})"
	printf '%s\n' "${metrics_body}" | sed 's/^/  /' | head -n 40
fi

printf '\n%d passed, %d failed, %d skipped\n' "${passed}" "${failed}" "${skipped}"
if test "${failed}" -ne 0
then
	exit 1
fi
exit 0
