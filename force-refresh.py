"""Make cswap read every account's usage now (the popout's Refresh button).

`cswap list` serves its stored reading until the account's poll plan says
otherwise: at least 3 minutes, and about 10 for an exhausted account. A reset
granted on claude.ai is invisible until then. This marks the accounts as due
and runs the collection `cswap auto` uses, so cswap still does the fetching:
backoff after errors and 429s, claims against concurrent collectors, token
refresh for inactive accounts, and the next poll plan.

Accounts read in the last MIN_AGE_S seconds are skipped: the usage endpoint
allows about 30 requests per hour per account, and cswap needs most of them.

Runs with cswap's own interpreter (see ClaudeSwapLogic.forceRefreshCommand).
It uses cswap internals, so any failure exits non-zero and the plugin falls
back to a plain `cswap list`. Prints the slots it asked for, e.g. "due 1 2".
"""

import sys

MIN_AGE_S = 30


def main() -> int:
    try:
        from claude_swap.switcher import ClaudeAccountSwitcher
    except ImportError:
        return 3

    switcher = ClaudeAccountSwitcher()
    store = switcher._usage_store
    info = switcher._build_accounts_info()
    identities = {str(num): (email, org_uuid or "") for num, email, _name, org_uuid, *_ in info}
    entries = store.entries(identities)
    now = store.clock()

    due = {
        num
        for num, entry in entries.items()
        if not entry.in_backoff(now)
        and not entry.held(now)
        and (entry.fetched_at is None or now - entry.fetched_at >= MIN_AGE_S)
    }
    if due:
        store.set_poll_plan({num: (now, entries[num].poll_interval_s) for num in due}, identities)
        switcher._collect_usage_entries(info, fetch=due)
    print("due", *sorted(due, key=int))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # cswap changed shape: let the plugin fall back
        print(f"{type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(2)
