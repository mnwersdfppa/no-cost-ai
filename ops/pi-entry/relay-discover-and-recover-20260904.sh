#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

printf '%s' __PASSWORD_Q__ >"$TMP/pass"
chmod 600 "$TMP/pass"
cat >"$TMP/askpass" <<'SH'
#!/bin/sh
cat "$PI_PASS_FILE"
SH
chmod 700 "$TMP/askpass"
export PI_PASS_FILE="$TMP/pass"

python3 - <<'PY' >"$TMP/candidates"
import concurrent.futures, ipaddress, socket, subprocess

RFC1918 = [
    ipaddress.ip_network('10.0.0.0/8'),
    ipaddress.ip_network('172.16.0.0/12'),
    ipaddress.ip_network('192.168.0.0/16'),
]

def private_v4(ip):
    return ip.version == 4 and any(ip in net for net in RFC1918)

candidates=set()
networks=set()
try:
    text=subprocess.check_output(['ip','-o','-4','addr','show','scope','global'], text=True, stderr=subprocess.DEVNULL)
except Exception:
    text=''
for line in text.splitlines():
    for tok in line.split():
        if '/' not in tok:
            continue
        try:
            iface=ipaddress.ip_interface(tok)
        except Exception:
            continue
        if private_v4(iface.ip):
            networks.add(ipaddress.ip_network(f'{iface.ip}/24', strict=False))

try:
    text=subprocess.check_output(['ip','neigh','show'], text=True, stderr=subprocess.DEVNULL)
except Exception:
    text=''
for line in text.splitlines():
    try:
        ip=ipaddress.ip_address(line.split()[0])
        if private_v4(ip):
            candidates.add(str(ip))
    except Exception:
        pass

def port22(ip):
    try:
        s=socket.create_connection((str(ip),22), timeout=0.25)
        s.close()
        return str(ip)
    except Exception:
        return None

hosts=[]
for net in networks:
    hosts.extend(list(net.hosts()))
hosts=hosts[:508]
with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
    for hit in pool.map(port22, hosts):
        if hit:
            candidates.add(hit)

for value in sorted(candidates, key=lambda s: tuple(map(int,s.split('.')))):
    print(value)
PY

COUNT="$(wc -l <"$TMP/candidates" | tr -d ' ')"
printf 'RELAY_CANDIDATES=%s\n' "$COUNT"

SAFE='MODEL=unknown; [ ! -r /proc/device-tree/model ] || MODEL=$(tr -d "\000" </proc/device-tree/model | tr -cd "A-Za-z0-9 ._/-" | head -c 120); printf "SAFE model=%s\n" "$MODEL"'
TARGET=''
while read -r ip; do
  [[ -n "$ip" ]] || continue
  INFO="$(timeout 10s env DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$TMP/askpass" setsid -w ssh -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=yes -o NumberOfPasswordPrompts=1 -o ConnectTimeout=3 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$TMP/known" -o LogLevel=ERROR "__PI_USER__@$ip" "$SAFE" 2>/dev/null || true)"
  if grep -Fq 'model=Raspberry Pi 5' <<<"$INFO"; then
    TARGET="$ip"
    break
  fi
done <"$TMP/candidates"

if [[ -z "$TARGET" ]]; then
  echo RELAY_PI_NOT_FOUND
  exit 20
fi

echo RELAY_PI_IDENTIFIED
base64 -d >"$TMP/runner" <<'RUNNER_B64'
__RUNNER_B64__
RUNNER_B64
chmod 700 "$TMP/runner"

if [[ -n '__BOOTSTRAP_Q__' ]]; then
  printf 'export ODI_BOOTSTRAP_TOKEN=%s\n' '__BOOTSTRAP_Q__' >"$TMP/entry"
  cat "$TMP/runner" >>"$TMP/entry"
else
  cp "$TMP/runner" "$TMP/entry"
fi

set +e
OUT="$(timeout 10m env DISPLAY=:0 SSH_ASKPASS_REQUIRE=force SSH_ASKPASS="$TMP/askpass" setsid -w ssh -o BatchMode=no -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=yes -o NumberOfPasswordPrompts=1 -o ConnectTimeout=5 -o ConnectionAttempts=1 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$TMP/known" -o LogLevel=ERROR "__PI_USER__@$TARGET" 'bash -s' <"$TMP/entry" 2>&1)"
RC=$?
set -e
printf '%s\n' "$OUT" | grep -E 'PHYSICAL_ENTRY_VERIFIED|SEQUENCE_ADVANCED|RECOVERY_OK|RESULT=|BLOCKED=' || true
if [[ $RC -eq 0 ]] && grep -Eq 'PHYSICAL_ENTRY_VERIFIED|SEQUENCE_ADVANCED|RECOVERY_OK' <<<"$OUT"; then
  echo RELAY_PI_EXECUTED
  exit 0
fi

echo RELAY_PI_RUNNER_FAILED
exit 21
