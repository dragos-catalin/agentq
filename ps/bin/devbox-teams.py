#!/usr/bin/env python3
"""devbox-teams: OS-enforced team permissions on a multi-user devbox (agentq ADR 0007).

Model
  * one Linux account per person (hub `linux_username`, u-<8hex>; the owner keeps `dev`)
  * one Unix group per repo, r-<repo>; /work/<repo> is owned by it, setgid, mode 2770, default ACL
    g::rwX o::--- so every file anyone creates stays group-only. /work/gh/<repo> -> /work/<repo> symlink.
  * agents run as their human's account (VS Code server, codaid, terminals), so a repo the human
    cannot read is invisible to their agents too: the kernel enforces it, not a prompt.
  * system agentq store /var/lib/agentq (group devbox-users): machine queues, workspace leases,
    journal; repo-scoped queue/lease dirs and journal.d/<repo>.jsonl belong to r-<repo>.
  * members removed from every repo are locked (password + expiry + ssh keys moved aside) and their
    processes killed; homes are never deleted by this tool.

Input (desired state, from devbox-team-sync on the owner's PC; no secrets inside):
  {"version":1, "owner":"dev", "ca_keys":["ssh-ed25519 AAAA..."],
   "repos":{"codai":{"members":[{"linux":"u-0f1d2c3e","role":"developer"}]}}}
  role: owner|maintainer|developer get the group; viewer gets nothing (no shell, like codaid).
  Repos absent from "repos" are owner-only (only `owner` is in r-<repo>).

Usage (root):  devbox-teams apply < teams.json      devbox-teams plan < teams.json      devbox-teams status
               devbox-teams apply --file teams.json [--work /work] [--dry-run]
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field

USER_RE = re.compile(r"^(u-[0-9a-f]{8}|[a-z_][a-z0-9_-]{0,31})$")
HUB_USER_RE = re.compile(r"^u-[0-9a-f]{8}$")
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$")
CA_RE = re.compile(r"^(ssh-ed25519|ecdsa-sha2-nistp256|ssh-rsa) [A-Za-z0-9+/=]{40,}( [^\s]{0,80})?$")
ROLES = {"owner", "maintainer", "developer", "viewer"}
SHELL_ROLES = {"owner", "maintainer", "developer"}
USERS_GROUP = "devbox-users"
MANAGED_MARK = "devbox-teams"  # GECOS of accounts this tool created (never touch others)
SYS = "/var/lib/agentq"
SLOT_NAMES = ["task-%d" % i for i in range(1, 13)] + ["release", "release-2", "land", "pinned"]


def group_name(repo: str) -> str:
    g = "r-" + re.sub(r"[^a-z0-9._-]", "-", repo.lower())
    return g[:32]


def journal_name(repo: str) -> str:
    return re.sub(r"[^a-z0-9._-]", "_", repo.lower()) + ".jsonl"


class Invalid(ValueError):
    pass


def validate(desired: dict) -> dict:
    """Strict schema check. Returns a normalised copy; raises Invalid with the first problem."""
    if not isinstance(desired, dict) or desired.get("version") != 1:
        raise Invalid("version must be 1")
    owner = desired.get("owner", "dev")
    if not isinstance(owner, str) or not USER_RE.match(owner) or owner == "root":
        raise Invalid("owner must be a plain Linux user name (not root)")
    cas = desired.get("ca_keys", [])
    if not isinstance(cas, list) or any(not isinstance(k, str) or not CA_RE.match(k.strip()) for k in cas):
        raise Invalid("ca_keys must be a list of ssh public key lines")
    repos = desired.get("repos", {})
    if not isinstance(repos, dict):
        raise Invalid("repos must be an object")
    out = {"version": 1, "owner": owner, "ca_keys": [k.strip() for k in cas], "repos": {}}
    for name, spec in repos.items():
        if not REPO_RE.match(name):
            raise Invalid(f"bad repo name {name!r}")
        members = (spec or {}).get("members", [])
        if not isinstance(members, list):
            raise Invalid(f"{name}: members must be a list")
        norm = []
        for m in members:
            linux, role = (m or {}).get("linux"), (m or {}).get("role")
            if role not in ROLES:
                raise Invalid(f"{name}: bad role {role!r}")
            if linux != owner and (not isinstance(linux, str) or not HUB_USER_RE.match(linux)):
                raise Invalid(f"{name}: member must be the owner or a hub u-<8hex> account, got {linux!r}")
            norm.append({"linux": linux, "role": role})
        out["repos"][name] = {"members": norm}
    return out


@dataclass
class State:
    """What exists on the machine (filled by scan(), or by a test)."""
    repos: list[str]                       # repo dirs present (in /work or /work/gh)
    moved: dict[str, bool]                 # repo -> already at /work/<repo> (not only /work/gh/<repo>)
    users: dict[str, dict]                 # name -> {"managed": bool, "locked": bool, "groups": set}
    groups: set[str] = field(default_factory=set)
    ca_keys: list[str] = field(default_factory=list)


def plan(desired: dict, st: State) -> list[tuple]:
    """Pure: the ordered list of actions that brings `st` to `desired`. Idempotent (empty when converged)."""
    d = validate(desired)
    owner = d["owner"]
    acts: list[tuple] = []
    if USERS_GROUP not in st.groups:
        acts.append(("groupadd", USERS_GROUP))
    want_members: dict[str, set[str]] = {}  # repo -> linux users with a shell role
    for repo in st.repos:
        mem = {owner}
        for m in d["repos"].get(repo, {}).get("members", []):
            if m["role"] in SHELL_ROLES:
                mem.add(m["linux"])
        want_members[repo] = mem
    for repo in d["repos"]:
        if repo not in st.repos:
            acts.append(("warn", f"repo {repo} has hub members but is not cloned on this devbox"))
    people = set().union(*want_members.values()) if want_members else {owner}
    for u in sorted(people):
        if u not in st.users:
            acts.append(("useradd", u))
        elif st.users[u]["locked"] and st.users[u]["managed"]:
            acts.append(("unlock", u))
        if USERS_GROUP not in (st.users.get(u, {}).get("groups") or set()):
            acts.append(("usermod-add", u, USERS_GROUP))
    for repo in sorted(st.repos):
        g = group_name(repo)
        if g not in st.groups:
            acts.append(("groupadd", g))
        if not st.moved.get(repo):
            acts.append(("move-repo", repo))
        acts.append(("perms-repo", repo, g))  # idempotent, cheap when already right (checked at run time)
        for u in sorted(want_members[repo]):
            if g not in (st.users.get(u, {}).get("groups") or set()):
                acts.append(("usermod-add", u, g))
        for u, info in sorted(st.users.items()):
            if info["managed"] and g in info["groups"] and u not in want_members[repo]:
                acts.append(("usermod-del", u, g))
    for u, info in sorted(st.users.items()):
        if info["managed"] and u not in people and not info["locked"]:
            acts.append(("offboard", u))
    if sorted(d["ca_keys"]) != sorted(st.ca_keys):
        acts.append(("ca-keys", d["ca_keys"]))
    acts.append(("system-store", sorted(st.repos)))
    return acts


# ---------------------------------------------------------------------------------------------- runtime
def sh(*cmd: str, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
    r = subprocess.run(list(cmd), capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} -> {r.returncode}: {r.stderr.strip()[:300]}")
    if not quiet and r.stdout.strip():
        print(r.stdout.strip())
    return r


def scan(work: str) -> State:
    import grp
    import pwd
    repos, moved = [], {}
    gh = os.path.join(work, "gh")
    names = set()
    for base in (work, gh):
        if os.path.isdir(base):
            for n in os.listdir(base):
                p = os.path.join(base, n)
                if REPO_RE.match(n) and not n.startswith(".") and os.path.isdir(os.path.join(p, ".git")) and n != "gh":
                    names.add(n)
    for n in sorted(names):
        p = os.path.join(work, n)
        repos.append(n)
        moved[n] = os.path.isdir(p) and not os.path.islink(p) and os.path.isdir(os.path.join(p, ".git")) and _is_team_repo(p)
    groups = {g.gr_name for g in grp.getgrall()}
    users = {}
    for p in pwd.getpwall():
        if p.pw_uid < 1000 or p.pw_uid >= 60000:
            continue
        gs = {g.gr_name for g in grp.getgrall() if p.pw_name in g.gr_mem}
        gs.add(grp.getgrgid(p.pw_gid).gr_name)
        locked = False
        try:
            locked = sh("passwd", "-S", p.pw_name, check=False, quiet=True).stdout.split()[1] == "L" and _expired(p.pw_name)
        except Exception:
            pass
        users[p.pw_name] = {"managed": MANAGED_MARK in (p.pw_gecos or ""), "locked": locked, "groups": gs}
    ca = []
    if os.path.exists("/etc/ssh/agentq_user_ca.pub"):
        ca = [ln.strip() for ln in open("/etc/ssh/agentq_user_ca.pub") if ln.strip()]
    return State(repos=repos, moved=moved, users=users, groups=groups, ca_keys=ca)


def _is_team_repo(p: str) -> bool:
    # /work/<repo> that this tool owns (created by move-repo). The devcloud runner used /work/<repo> for job
    # checkouts before it moved to /work/.jobs: such a dir is NOT the team repo and must be moved aside first.
    return os.path.exists(os.path.join(p, ".git", "devbox-teams"))


def _expired(u: str) -> bool:
    r = sh("chage", "-l", u, check=False, quiet=True).stdout
    return "Account expires" in r and "never" not in r.split("Account expires", 1)[1].splitlines()[0]


def pwd_uid(u: str) -> int:
    import pwd
    return pwd.getpwnam(u).pw_uid


def set_tree_perms(path: str, g: str) -> None:
    # chgrp/chmod only where needed (a warm repo with node_modules has millions of inodes)
    sh("chgrp", "-R", "-h", "--preserve-root", g, path)
    sh("chmod", "-R", "g+rwX,o-rwx", path)
    sh("find", path, "-type", "d", "-exec", "chmod", "g+s", "{}", "+")
    sh("setfacl", "-R", "-m", "d:g::rwX,d:o::---,d:m::rwx", path)
    os.chmod(path, 0o2770)


def act(a: tuple, work: str, owner: str, dry: bool) -> None:
    import grp
    print("->", a[0], *[x for x in a[1:] if isinstance(x, str)])
    if dry:
        return
    k = a[0]
    if k == "warn":
        print("   WARN", a[1])
    elif k == "groupadd":
        sh("groupadd", "-f", a[1])
    elif k == "useradd":
        u = a[1]
        sh("useradd", "-m", "-s", "/bin/bash", "-c", f"{MANAGED_MARK} hub member", "-K", "UMASK=0077", u)
        os.chmod(f"/home/{u}", 0o750)
        sh("passwd", "-l", u, quiet=True)  # key/cert login only
        # per-user agentq store + pnpm store in the user's home (never shared)
        os.makedirs(f"/home/{u}/.codai/coord", mode=0o700, exist_ok=True)
        sh("chown", "-R", f"{u}:{u}", f"/home/{u}/.codai")
    elif k == "unlock":
        u = a[1]
        sh("usermod", "--expiredate", "", u)
        aside = f"/home/{u}/.ssh/authorized_keys.offboarded"
        if os.path.exists(aside):
            os.replace(aside, f"/home/{u}/.ssh/authorized_keys")
        print(f"   restored {u}")
    elif k == "usermod-add":
        sh("usermod", "-aG", a[2], a[1])
    elif k == "usermod-del":
        sh("gpasswd", "-d", a[1], a[2], quiet=True)
        sh("pkill", "-HUP", "-u", a[1], check=False)  # drop sessions so the old group list is gone
    elif k == "offboard":
        u = a[1]
        sh("passwd", "-l", u, quiet=True)
        sh("usermod", "--expiredate", "1", u)
        ak = f"/home/{u}/.ssh/authorized_keys"
        if os.path.exists(ak):
            os.replace(ak, ak + ".offboarded")
        sh("pkill", "-KILL", "-u", u, check=False)
        print(f"   {u} locked, processes killed, home kept")
    elif k == "move-repo":
        repo = a[1]
        dst, src = os.path.join(work, repo), os.path.join(work, "gh", repo)
        if os.path.isdir(dst) and not os.path.islink(dst) and not _is_team_repo(dst):
            jobs = os.path.join(work, ".jobs")
            os.makedirs(jobs, exist_ok=True)
            shutil.chown(jobs, owner, owner)  # the devcloud runner runs as the owner and writes .known-*.json here
            os.chmod(jobs, 0o700)
            aside = os.path.join(jobs, repo)
            if os.path.exists(aside):
                aside = f"{aside}.{int(time.time())}"
            os.rename(dst, aside)  # old devcloud runner checkout, rebuilt by the runner on demand
            print(f"   runner checkout {dst} -> {aside}")
        if os.path.isdir(src) and not os.path.islink(src):
            os.rename(src, dst)
        if not os.path.lexists(src):
            os.symlink(dst, src)
        open(os.path.join(dst, ".git", "devbox-teams"), "w").write("team repo (devbox-teams)\n")
    elif k == "perms-repo":
        repo, g = a[1], a[2]
        p = os.path.join(work, repo)
        st = os.stat(p)
        if st.st_gid != grp.getgrnam(g).gr_gid or (st.st_mode & 0o7777) != 0o2770:
            set_tree_perms(p, g)
        # git's "dubious ownership" check: members are not the files' owner. Trust exactly the team paths.
        # (must come first: root running `git -C <repo>` on a dev-owned repo fails with "not in a git directory")
        have = sh("git", "config", "--system", "--get-all", "safe.directory", check=False, quiet=True).stdout.split()
        for sp in [p] + [os.path.join(work, ".wt", repo, s) for s in SLOT_NAMES]:
            if sp not in have:
                sh("git", "config", "--system", "--add", "safe.directory", sp)
        sh("git", "config", "--file", os.path.join(p, ".git", "config"), "core.sharedRepository", "group")
        wt = os.path.join(work, ".wt", repo)
        os.makedirs(wt, exist_ok=True)
        st = os.stat(wt)
        if st.st_gid != grp.getgrnam(g).gr_gid or (st.st_mode & 0o7777) != 0o2770:
            set_tree_perms(wt, g)
    elif k == "ca-keys":
        keys = a[1]
        with open("/etc/ssh/agentq_user_ca.pub.new", "w") as f:
            f.write("".join(k2 + "\n" for k2 in keys))
        os.chmod("/etc/ssh/agentq_user_ca.pub.new", 0o644)
        os.replace("/etc/ssh/agentq_user_ca.pub.new", "/etc/ssh/agentq_user_ca.pub")
        conf = "/etc/ssh/sshd_config.d/60-agentq-user-ca.conf"
        with open(conf, "w") as f:
            # hub-issued member certificates (principal = linux_username); plain keys keep working
            f.write("TrustedUserCAKeys /etc/ssh/agentq_user_ca.pub\n")
        if sh("sshd", "-t", check=False, quiet=True).returncode != 0:
            os.remove(conf)
            raise RuntimeError("sshd -t rejected the CA config; removed it")
        sh("systemctl", "reload", "ssh", check=False)
    elif k == "system-store":
        system_store(a[1], owner)
        st = os.stat(work)
        if st.st_uid != 0 or (st.st_mode & 0o022):
            os.chown(work, 0, 0)  # a user-owned /work could rename or replace another group's repo
            os.chmod(work, 0o755)
        jobs = os.path.join(work, ".jobs")  # runner job checkouts (owner-only, never a team tree)
        os.makedirs(jobs, exist_ok=True)
        if os.stat(jobs).st_uid != pwd_uid(owner):
            sh("chown", "-R", f"{owner}:{owner}", jobs)
        os.chmod(jobs, 0o700)


def system_store(repos: list[str], owner: str) -> None:
    """Create/repair /var/lib/agentq: shared dirs (devbox-users) and repo dirs (r-<repo>), all 2770 + default ACL."""
    def mk(path: str, g: str, mode: int = 0o2770) -> None:
        os.makedirs(path, exist_ok=True)
        shutil.chown(path, "root", g)
        os.chmod(path, mode)
        sh("setfacl", "-m", "d:g::rwX,d:o::---,d:m::rwx", path)
    mk(SYS, USERS_GROUP)
    for d in ("queues", "marks", "leases", "releases", "workspaces", "journal.d", "cloud-down", "batches", "flakes"):
        mk(os.path.join(SYS, d), USERS_GROUP)
    for q in ("build_machine",):
        mk(os.path.join(SYS, "queues", q), USERS_GROUP)
    for repo in repos:
        g = group_name(repo)
        r = repo.lower()
        for kind in ("build", "install", "commit", "land", "release"):
            mk(os.path.join(SYS, "queues", f"{kind}_{r}"), g)
        mk(os.path.join(SYS, "leases", r), g)
        mk(os.path.join(SYS, "batches", r), g)
        jf = os.path.join(SYS, "journal.d", journal_name(repo))
        if not os.path.exists(jf):
            open(jf, "a").close()
        shutil.chown(jf, "root", g)
        os.chmod(jf, 0o660)
    jf = os.path.join(SYS, "journal.jsonl")
    if not os.path.exists(jf):
        open(jf, "a").close()
    shutil.chown(jf, "root", USERS_GROUP)
    os.chmod(jf, 0o660)
    sj = os.path.join(SYS, "system.json")
    if not os.path.exists(sj):
        nproc = os.cpu_count() or 8
        pol = {"machineCap": max(2, nproc // 8), "taskSlotsMachine": 12, "taskSlotsPerRepo": 6, "quickBurst": 2}
        with open(sj, "w") as f:
            json.dump({"version": 1, "owner": owner, "policy": pol, "note": "machine policy for every user; edit as root"}, f, indent=2)
    shutil.chown(sj, "root", USERS_GROUP)
    os.chmod(sj, 0o644)


def main(argv: list[str]) -> int:
    import argparse
    ap = argparse.ArgumentParser(prog="devbox-teams")
    ap.add_argument("cmd", choices=["apply", "plan", "status"])
    ap.add_argument("--file")
    ap.add_argument("--work", default="/work")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "status":
        st = scan(a.work)
        for r in st.repos:
            g = group_name(r)
            mem = sorted(u for u, i in st.users.items() if g in i["groups"])
            print(f"{r:24} {g:24} moved={st.moved.get(r)} members={','.join(mem)}")
        for u, i in sorted(st.users.items()):
            if i["managed"]:
                print(f"user {u} locked={i['locked']}")
        return 0
    raw = open(a.file).read() if a.file else sys.stdin.read()
    if len(raw) > 1_000_000:
        print("desired state too large", file=sys.stderr)
        return 2
    try:
        desired = validate(json.loads(raw))
    except (Invalid, json.JSONDecodeError) as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    if os.geteuid() != 0 and not a.dry_run and a.cmd == "apply":
        print("apply needs root", file=sys.stderr)
        return 2
    st = scan(a.work)
    acts = plan(desired, st)
    dry = a.dry_run or a.cmd == "plan"
    for x in acts:
        act(x, a.work, desired["owner"], dry)
    if not dry:
        os.makedirs("/etc/agentq", exist_ok=True)
        with open("/etc/agentq/teams.json", "w") as f:
            json.dump(desired, f, indent=2)
        print("TEAMS_APPLIED", len(acts))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
