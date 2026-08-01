"""One request's worth of memoized answers, and nothing longer.

Every scoped page and endpoint asks the same few questions repeatedly while
building one response: is this employee an admin, what is their cadre, which
lines does their reporting subtree hold, which towers do those lines carry. Each
answer costs at least a query, and the subtree walk reads the whole
EmployeeCadreSnapshot table (see viewing.subordinate_snapshots) — yet within a
single response they cannot legitimately change. `oversight_towers()` alone
needed the subtree twice, and the mobile dashboard asked for it four times over.

So the answers are memoized for the life of one request. The window is opened and
closed by `ScopeMemoMiddleware` (middleware.py), which closes it on the exception
path too: threads are reused, and a memo left behind would answer for the wrong
employee.

Why not cache across requests: these answers are permission boundaries. An
assignment revoked or an admin grant withdrawn must take effect on the very next
request, not when a TTL expires. Within one request there is nothing to gain from
staleness and nothing to lose by memoizing.

With no window open — a management command, a shell, a direct unit test — every
call recomputes exactly as it did before, so nothing here changes behaviour
outside a request.
"""
import threading

_local = threading.local()


def begin():
    """Open a fresh memo for this thread."""
    _local.memo = {}


def end():
    """Discard it, so nothing survives the response."""
    _local.memo = None


def memoized(key, compute):
    """`compute()`, once per [key] per request. Uncached when no window is open."""
    memo = getattr(_local, 'memo', None)
    if memo is None:
        return compute()
    if key not in memo:
        memo[key] = compute()
    return memo[key]
