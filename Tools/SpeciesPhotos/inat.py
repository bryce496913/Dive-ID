"""A small, polite iNaturalist API client: identified, throttled and cached.

iNaturalist asks API users to stay at or below about one request per second (and about
10,000 a day) and to identify themselves. When it answers 429 the client slows down for the
rest of the run: the gap between requests doubles (up to MAX_INTERVAL) and any Retry-After
is honoured. Every response is cached on disk with the time it was fetched, so a
rerun (or --offline) makes no requests and reproduces the same manifest.
"""
import datetime as dt
import hashlib
import http.client
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.inaturalist.org/v1"
USER_AGENT = "DiveID-SpeciesPhotos/1.0 (non-commercial dive identification app; +https://github.com/bryce496913/Dive-ID)"
PHOTO_PAGE = "https://www.inaturalist.org/photos/{id}"
OBSERVATION_PAGE = "https://www.inaturalist.org/observations/{id}"
TAXON_PAGE = "https://www.inaturalist.org/taxa/{id}"


MAX_INTERVAL = 120.0
THROTTLE_ATTEMPTS = 6


class Throttled(Exception):
    """iNaturalist answered 429. retry_after: seconds it asked us to wait, if it said."""
    def __init__(self, retry_after=None):
        super().__init__(f"429 Too Many Requests (Retry-After: {retry_after})")
        self.retry_after = retry_after


class Offline(Exception):
    """A request that is not cached while running offline."""


class Client:
    def __init__(self, cache_dir, offline=False, minimum_interval=1.0, opener=None, clock=time.monotonic, sleep=time.sleep,
                 log=None, log_every=100):
        self.cache_dir = Path(cache_dir)
        self.offline = offline
        self.minimum_interval = minimum_interval
        self.opener = opener or self._open
        self.clock, self.sleep = clock, sleep
        self._last = None
        self.requests = 0
        self.throttled = 0
        self.log, self.log_every = log, log_every

    def get(self, path, params, trim=None):
        """(body, fetched date). trim reduces the body to what the pipeline reads before it is
        cached: a full observation page is about 1.5 MB, so the whole catalogue would not fit."""
        url = API + path + "?" + urllib.parse.urlencode(sorted(params.items()))
        cached = self.cache_dir / (hashlib.sha256(url.encode()).hexdigest() + ".json")
        if cached.exists():
            entry = json.loads(cached.read_text())
            return entry["body"], entry["fetchedAt"]
        if self.offline:
            raise Offline(url)
        for attempt in range(THROTTLE_ATTEMPTS):
            if self._last is not None:
                wait = self.minimum_interval - (self.clock() - self._last)
                if wait > 0:
                    self.sleep(wait)
            self._last = self.clock()
            try:
                body = self.opener(url)
                break
            except Throttled as throttled:
                # Refused: slow down for good, and wait as long as asked before trying again.
                self.throttled += 1
                self.minimum_interval = min(max(self.minimum_interval * 2, 2.0), MAX_INTERVAL)
                if self.log:
                    self.log(f"429 from iNaturalist: now {self.minimum_interval:g} s between requests "
                             f"(Retry-After {throttled.retry_after})")
                if attempt == THROTTLE_ATTEMPTS - 1:
                    raise
                self.sleep(max(throttled.retry_after or 0, self.minimum_interval))
                self._last = None  # that wait already covers the gap before the retry
        self.requests += 1
        if self.log and self.requests % self.log_every == 0:
            self.log(f"{dt.datetime.now():%H:%M:%S} requests={self.requests} throttled={self.throttled} "
                     f"interval={self.minimum_interval:g}s")
        if trim:
            body = trim(body)
        fetched = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        cached.write_text(json.dumps({"url": url, "fetchedAt": fetched, "body": body}, sort_keys=True))
        return body, fetched

    @staticmethod
    def _open(url):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        for attempt in range(4):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    return json.loads(response.read().decode())
            except urllib.error.HTTPError as error:
                if error.code == 429:
                    # The caller slows down for the rest of the run (Client.get).
                    retry_after = error.headers.get("Retry-After") if error.headers else None
                    raise Throttled(float(retry_after) if retry_after and retry_after.isdigit() else None) from error
                # 5xx: back off and retry; anything else is a real failure.
                if error.code not in (500, 502, 503, 504) or attempt == 3:
                    raise
                time.sleep(10 * (attempt + 1))
            except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError):
                # A dropped connection or timeout: back off and retry, as for 5xx.
                if attempt == 3:
                    raise
                time.sleep(10 * (attempt + 1))
        raise RuntimeError("unreachable")

    def taxa(self, scientific_name):
        return self.get("/taxa", {"q": scientific_name, "rank": "species", "per_page": 10}, trim=trim_taxa)

    def observations(self, taxon_id, licences, per_page=30):
        return self.get("/observations", {
            "taxon_id": taxon_id, "quality_grade": "research", "photos": "true",
            "photo_license": ",".join(licences), "order_by": "votes", "per_page": per_page,
        }, trim=trim_observations)


TAXON_FIELDS = ("id", "name", "rank", "matched_term", "is_active")
OBSERVATION_FIELDS = ("id", "quality_grade", "captive", "observed_on")
USER_FIELDS = ("id", "login", "name")
PHOTO_FIELDS = ("id", "license_code", "original_dimensions", "url", "attribution", "flags", "hidden")


def _keep(item, fields):
    return {k: item[k] for k in fields if k in item}


def trim_taxa(body):
    return {"total_results": body.get("total_results"), "results": [_keep(t, TAXON_FIELDS) for t in body.get("results", [])]}


def trim_observations(body):
    return {"total_results": body.get("total_results"), "results": [
        dict(_keep(o, OBSERVATION_FIELDS), user=_keep(o.get("user") or {}, USER_FIELDS),
             photos=[_keep(p, PHOTO_FIELDS) for p in o.get("photos", [])])
        for o in body.get("results", [])]}
