import logging
import os
import threading
import time
from collections import OrderedDict

from django.http import JsonResponse

logger = logging.getLogger(__name__)


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default


class IPRateLimitMiddleware:
    """In-memory per-IP rate limit for /prediction/ endpoints.

    State is per-instance (Cloud Run container). With max-instances=N the
    effective burst capacity is N × the configured limit.
    """

    PATH_PREFIX = "/prediction/"

    def __init__(self, get_response):
        self.get_response = get_response
        self._lock = threading.Lock()
        self._buckets: "OrderedDict[str, dict]" = OrderedDict()
        self._limit_per_min = _int_env("RATELIMIT_PER_MIN", 30)
        self._limit_per_hour = _int_env("RATELIMIT_PER_HOUR", 200)
        self._max_tracked_ips = _int_env("RATELIMIT_LRU_SIZE", 10000)

    def __call__(self, request):
        if not request.path.startswith(self.PATH_PREFIX):
            return self.get_response(request)

        ip = self._client_ip(request)
        now = time.time()

        with self._lock:
            entry = self._buckets.get(ip)
            if entry is None:
                entry = {"min": [], "hour": []}
                self._buckets[ip] = entry
            else:
                self._buckets.move_to_end(ip)

            entry["min"] = [t for t in entry["min"] if now - t < 60]
            entry["hour"] = [t for t in entry["hour"] if now - t < 3600]

            if len(entry["min"]) >= self._limit_per_min:
                logger.warning("rate-limit per-min hit ip=%s path=%s", ip, request.path)
                return self._limited_response("per-minute", self._limit_per_min)
            if len(entry["hour"]) >= self._limit_per_hour:
                logger.warning("rate-limit per-hour hit ip=%s path=%s", ip, request.path)
                return self._limited_response("per-hour", self._limit_per_hour)

            entry["min"].append(now)
            entry["hour"].append(now)

            while len(self._buckets) > self._max_tracked_ips:
                self._buckets.popitem(last=False)

        return self.get_response(request)

    @staticmethod
    def _client_ip(request) -> str:
        xff = request.META.get("HTTP_X_FORWARDED_FOR", "")
        if xff:
            return xff.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "unknown")

    @staticmethod
    def _limited_response(scope: str, limit: int) -> JsonResponse:
        return JsonResponse(
            {"error": f"Rate limit exceeded ({scope}, limit={limit})"},
            status=429,
            json_dumps_params={"ensure_ascii": False},
        )
