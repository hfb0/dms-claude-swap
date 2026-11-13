# Stand-in for claude_swap.switcher: just the internals force-refresh.py touches.
# Logs each call to $FAKE_LOG; $FAKE_MODE=broken makes the switcher blow up.
import json
import os

NOW = 1000.0


class Entry:
    def __init__(self, fetched_at, backoff_until=None, held_until=None, poll_interval_s=600.0):
        self.fetched_at, self.backoff_until = fetched_at, backoff_until
        self.held_until, self.poll_interval_s = held_until, poll_interval_s

    def in_backoff(self, now):
        return self.backoff_until is not None and now < self.backoff_until

    def held(self, now):
        return self.held_until is not None and now < self.held_until


ENTRIES = {
    "1": Entry(NOW - 10),                       # read 10 s ago: skipped
    "2": Entry(NOW - 300, poll_interval_s=270),  # due
    "3": Entry(NOW - 300, backoff_until=NOW + 60),
    "4": Entry(NOW - 300, held_until=NOW + 60),  # adopted from another machine
    "5": Entry(None, poll_interval_s=None),     # never read: due
}


def log(*call):
    with open(os.environ["FAKE_LOG"], "a") as f:
        f.write(json.dumps(call) + "\n")


class Store:
    def clock(self):
        return NOW

    def entries(self, identities):
        assert set(identities) == set(ENTRIES)
        return ENTRIES

    def set_poll_plan(self, plans, identities):
        log("plan", {n: list(p) for n, p in plans.items()})


class ClaudeAccountSwitcher:
    def __init__(self):
        if os.environ.get("FAKE_MODE") == "broken":
            raise AttributeError("no _usage_store")
        self._usage_store = Store()

    def _build_accounts_info(self):
        return [(int(n), f"{n}@x", "Org", "org-" + n, n == "1", "creds", "") for n in ENTRIES]

    def _collect_usage_entries(self, accounts_info, fetch=None):
        log("collect", sorted(fetch))
