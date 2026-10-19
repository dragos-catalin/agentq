#!/usr/bin/env bash
# Done-means 5: a member without access to a repo cannot read it, nor can processes ("agents") they start.
# Test account u-7e570001 = member of r-agentq only (applied through devbox-teams with a test desired state,
# then the real state from /etc/agentq/teams.json is re-applied so the box ends exactly as the hub says).
set -u
T=u-7e570001
pass=0; fail=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
ko() { echo "FAIL $1"; fail=$((fail+1)); }
real=/tmp/teams-real.json
cp /etc/agentq/teams.json "$real"   # apply rewrites /etc/agentq/teams.json: keep the hub state aside
sig=$(head -c 24 /work/agentq/.gitattributes)
python3 - "$real" "$T" > /tmp/teams-test.json <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["repos"].setdefault("agentq", {"members": []})["members"].append({"linux": sys.argv[2], "role": "developer"})
print(json.dumps(d))
EOF
devbox-teams apply --file /tmp/teams-test.json | tail -1
id "$T" >/dev/null && ok "account $T created by devbox-teams" || ko "account $T"
as() { sudo -u "$T" -H bash -lc "$1" 2>&1; }
# allowed repo
[ "$(as 'head -c 24 /work/agentq/.gitattributes')" = "$sig" ] && ok "member reads /work/agentq" || ko "member reads /work/agentq: $(as 'head -c 80 /work/agentq/.gitattributes')"
as 'cd /work/agentq && git status --porcelain | wc -l' | grep -qE '^[0-9]+$' && ok "member runs git in /work/agentq" || ko "git in agentq: $(as 'cd /work/agentq && git status 2>&1 | head -2')"
as 'touch /work/agentq/.copilot-tmp-isotest && stat -c "%G %a" /work/agentq/.copilot-tmp-isotest && rm /work/agentq/.copilot-tmp-isotest' | grep -q '^r-agentq 66' && ok "new file inherits r-agentq, group rw, no other" || ko "file mode: $(as 'touch /work/agentq/.x; stat -c "%G %a" /work/agentq/.x; rm -f /work/agentq/.x')"
# forbidden repo, from the shell
as 'ls /work/codai' | grep -qi 'permission denied' && ok "ls /work/codai denied" || ko "ls /work/codai: $(as 'ls /work/codai | head -2')"
as 'cat /work/codai/package.json' | grep -qi 'permission denied' && ok "read /work/codai file denied" || ko "read codai file"
as 'cat /work/gh/codai/package.json' | grep -qi 'permission denied' && ok "old path /work/gh/codai denied too" || ko "old path"
as 'git -C /work/codai log -1' | grep -qiE 'permission denied|not a git' && ok "git on codai denied" || ko "git codai"
as 'mv /work/codai /work/codai-x' | grep -qi 'denied' && [ -d /work/codai ] && ok "cannot rename/replace a team repo" || ko "rename /work/codai"
# forbidden repo, from a child process the member starts (stand-in for their agent: node + pwsh)
as 'node -e "require(\"fs\").readFileSync(\"/work/codai/package.json\")"' | grep -q EACCES && ok "agent (node child) cannot read codai" || ko "node child"
as 'pwsh -NoProfile -c "Get-Content /work/codai/package.json"' | grep -qiE 'denied|unauthorized' && ok "agent (pwsh child) cannot read codai" || ko "pwsh child"
as 'nohup bash -c "cat /work/codai/package.json" > /tmp/iso-bg.out 2>&1; cat /tmp/iso-bg.out; rm -f /tmp/iso-bg.out' | grep -qi denied && ok "background job cannot read codai" || ko "bg job"
# system agentq: the codai journal and queues are closed to the member, agentq ones open
as 'cat /var/lib/agentq/journal.d/codai.jsonl' | grep -qi denied && ok "codai journal unreadable" || ko "codai journal"
as 'ls /var/lib/agentq/queues/build_codai' | grep -qi denied && ok "codai queue dir unreadable" || ko "codai queue"
as 'ls /var/lib/agentq/leases/codai' | grep -qi denied && ok "codai leases unreadable" || ko "codai leases"
as 'cd /work/codai 2>/dev/null; agentq run -Resource build -Repo /work/codai -Purpose isotest -MinFreeGB 0 -- true; echo RC=$?' | grep -q 'RC=[1-9]' && ok "agentq run on codai refused" || ko "agentq run codai"
out=$(as 'cd /work/agentq && agentq run -Resource build -Purpose isotest-agentq -MinFreeGB 0 -- true; echo RC=$?')
echo "$out" | grep -q 'RC=0' && ok "agentq run on agentq works (system queue)" || ko "agentq run agentq: $(echo "$out" | tail -3)"
grep -q isotest-agentq /var/lib/agentq/journal.d/agentq.jsonl && ok "event landed in journal.d/agentq.jsonl" || ko "agentq journal"
grep -q isotest-agentq /var/lib/agentq/journal.jsonl && ko "repo event leaked into the shared journal" || ok "repo event not in the shared journal"
# owner (dev) sees everything; per-user store is private
sudo -u dev -H bash -lc 'head -c1 /work/codai/package.json' >/dev/null 2>&1 && ok "owner dev reads codai" || ko "owner dev"
as 'ls /home/dev' | grep -qi denied && ok "member cannot read owner home (keys, .env)" || ko "home"
stat -c '%a' "/home/$T/.codai/coord" | grep -q '^700' && ok "per-user agentq store 0700" || ko "user store mode"
# offboard: removing the member (re-apply the real state) locks the account and drops access
devbox-teams apply --file "$real" | tail -1
[ "$(as 'head -c 24 /work/agentq/.gitattributes')" != "$sig" ] && ok "after removal: access gone ($(as 'head -c 24 /work/agentq/.gitattributes' | head -1 | cut -c1-60))" || ko "after removal: member still reads agentq"
id -nG "$T" | grep -q r-agentq && ko "after removal: still in r-agentq" || ok "after removal: not in r-agentq"
chage -l "$T" | grep -q 'Account expires.*1970' && ok "after removal: account expired, home kept ($(test -d /home/$T && echo yes))" || ko "expiry"
rm -f /tmp/teams-test.json "$real"
echo "ISOLATION pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
