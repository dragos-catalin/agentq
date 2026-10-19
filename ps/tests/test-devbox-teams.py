"""Unit tests for devbox-teams' pure planner (ADR 0007). Run: python test-devbox-teams.py [path/to/devbox-teams.py]"""
import importlib.util
import os
import sys
import unittest

TOOL = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1].endswith(".py") else os.path.join(os.path.dirname(__file__), "..", "bin", "devbox-teams.py")
spec = importlib.util.spec_from_file_location("devbox_teams", TOOL)
dt = importlib.util.module_from_spec(spec)
sys.modules["devbox_teams"] = dt
spec.loader.exec_module(dt)

ANA, BOB = "u-0f1d2c3e", "u-aaaabbbb"


def desired(**repos):
    return {"version": 1, "owner": "dev", "ca_keys": [], "repos": {k: {"members": v} for k, v in repos.items()}}


def state(repos=("codai", "axiom"), users=None, moved=True, groups=None):
    users = users if users is not None else {"dev": {"managed": False, "locked": False, "groups": {"dev", "devbox-users"} | {dt.group_name(r) for r in repos}}}
    gs = groups if groups is not None else {"devbox-users"} | {dt.group_name(r) for r in repos}
    return dt.State(repos=list(repos), moved={r: moved for r in repos}, users=users, groups=gs, ca_keys=[])


def kinds(acts, k):
    return [a for a in acts if a[0] == k]


class Validate(unittest.TestCase):
    def test_rejects_root_owner_and_bad_roles(self):
        for bad in ({"version": 2}, {"version": 1, "owner": "root"}, desired(codai=[{"linux": ANA, "role": "god"}])):
            with self.assertRaises(dt.Invalid):
                dt.validate(bad)

    def test_only_hub_accounts_or_owner(self):
        # a desired state must never be able to grant an arbitrary system account (root, www-data, dev2...)
        for name in ("root", "www-data", "ubuntu", "u-XYZ", "u-123", "../etc"):
            with self.assertRaises(dt.Invalid, msg=name):
                dt.validate(desired(codai=[{"linux": name, "role": "developer"}]))

    def test_bad_repo_names(self):
        with self.assertRaises(dt.Invalid):
            dt.validate(desired(**{"../x": []}))

    def test_ca_keys_shape(self):
        with self.assertRaises(dt.Invalid):
            dt.validate({"version": 1, "owner": "dev", "ca_keys": ["not a key"], "repos": {}})
        ok = "ssh-ed25519 " + "A" * 68 + " codai-ca"
        self.assertEqual(dt.validate({"version": 1, "owner": "dev", "ca_keys": [ok], "repos": {}})["ca_keys"], [ok])


class Plan(unittest.TestCase):
    def test_converged_state_only_refreshes_perms(self):
        acts = dt.plan(desired(), state())
        self.assertEqual({a[0] for a in acts}, {"perms-repo", "system-store"})

    def test_new_member_gets_account_and_only_their_repo(self):
        acts = dt.plan(desired(codai=[{"linux": ANA, "role": "developer"}]), state())
        self.assertIn(("useradd", ANA), acts)
        self.assertIn(("usermod-add", ANA, "r-codai"), acts)
        self.assertNotIn(("usermod-add", ANA, "r-axiom"), acts)
        self.assertIn(("usermod-add", ANA, "devbox-users"), acts)

    def test_viewer_gets_nothing(self):
        acts = dt.plan(desired(codai=[{"linux": ANA, "role": "viewer"}]), state())
        self.assertFalse([a for a in acts if len(a) > 1 and a[1] == ANA])

    def test_removed_from_one_repo_loses_that_group_only(self):
        users = state().users | {ANA: {"managed": True, "locked": False, "groups": {ANA, "devbox-users", "r-codai", "r-axiom"}}}
        acts = dt.plan(desired(axiom=[{"linux": ANA, "role": "developer"}]), state(users=users))
        self.assertIn(("usermod-del", ANA, "r-codai"), acts)
        self.assertNotIn(("usermod-del", ANA, "r-axiom"), acts)
        self.assertFalse(kinds(acts, "offboard"))

    def test_removed_everywhere_is_offboarded_not_deleted(self):
        users = state().users | {ANA: {"managed": True, "locked": False, "groups": {ANA, "r-codai"}}}
        acts = dt.plan(desired(), state(users=users))
        self.assertIn(("offboard", ANA), acts)
        self.assertIn(("usermod-del", ANA, "r-codai"), acts)
        self.assertFalse([a for a in acts if a[0] in ("userdel", "rm")])

    def test_unmanaged_accounts_are_never_touched(self):
        users = state().users | {"ubuntu": {"managed": False, "locked": False, "groups": {"ubuntu", "r-codai"}}}
        acts = dt.plan(desired(), state(users=users))
        self.assertFalse([a for a in acts if len(a) > 1 and a[1] == "ubuntu"])

    def test_returning_member_is_unlocked(self):
        users = state().users | {ANA: {"managed": True, "locked": True, "groups": {ANA, "devbox-users"}}}
        acts = dt.plan(desired(codai=[{"linux": ANA, "role": "developer"}]), state(users=users))
        self.assertIn(("unlock", ANA), acts)
        self.assertNotIn(("useradd", ANA), acts)

    def test_repos_not_yet_moved_are_moved_and_get_groups(self):
        acts = dt.plan(desired(), state(moved=False, groups={"devbox-users"}))
        self.assertIn(("move-repo", "codai"), acts)
        self.assertIn(("groupadd", "r-codai"), acts)
        # groupadd before move before perms
        i = acts.index
        self.assertLess(i(("groupadd", "r-codai")), i(("move-repo", "codai")))
        self.assertLess(i(("move-repo", "codai")), i(("perms-repo", "codai", "r-codai")))

    def test_repo_without_hub_env_is_owner_only(self):
        acts = dt.plan(desired(codai=[{"linux": BOB, "role": "maintainer"}]), state())
        self.assertNotIn(("usermod-add", BOB, "r-axiom"), acts)
        self.assertIn(("usermod-add", BOB, "r-codai"), acts)

    def test_member_of_uncloned_repo_is_a_warning(self):
        acts = dt.plan(desired(brivio=[{"linux": BOB, "role": "developer"}]), state())
        self.assertTrue([a for a in acts if a[0] == "warn" and "brivio" in a[1]])
        self.assertNotIn(("useradd", BOB), acts)

    def test_idempotent_after_apply(self):
        users = state().users | {ANA: {"managed": True, "locked": False, "groups": {ANA, "devbox-users", "r-codai"}}}
        acts = dt.plan(desired(codai=[{"linux": ANA, "role": "developer"}]), state(users=users))
        self.assertEqual({a[0] for a in acts}, {"perms-repo", "system-store"})

    def test_group_names(self):
        self.assertEqual(dt.group_name("Codai"), "r-codai")
        self.assertEqual(dt.group_name("a" * 50), "r-" + "a" * 30)
        self.assertEqual(dt.journal_name("My.Repo"), "my.repo.jsonl")


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
