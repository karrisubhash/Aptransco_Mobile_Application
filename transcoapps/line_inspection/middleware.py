"""Per-request lifecycle hooks for the line-inspection app."""
from . import request_scope


class ScopeMemoMiddleware:
    """Opens the per-request memo (request_scope.py) around each response.

    Identity, cadre and oversight-scope answers are asked for repeatedly while
    one page or endpoint is built — the mobile dashboard alone resolved the
    reporting subtree four times — and cannot legitimately change inside a single
    request. See request_scope.py for why the window closes with the response
    rather than becoming a cache.

    Install it after Django's own middleware; it neither reads nor writes the
    request or the response.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        request_scope.begin()
        try:
            return self.get_response(request)
        finally:
            # Also on the exception path: threads are reused, and a memo left
            # behind would answer for the wrong employee.
            request_scope.end()
