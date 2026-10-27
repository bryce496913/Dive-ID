"""A small, polite iNaturalist API client: identified, throttled and cached.

iNaturalist asks API users to stay at or below about one request per second and to
identify themselves. Every response is cached on disk with the time it was fetched, so a
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


class Offline(Exception):
    """A request that is not cached while running offline."""


class Client:
    def __init__(self, cache_dir, offline=False, minimum_interval=1.0, opener=None, clock=time.monotonic, sleep=time.sleep):
        self.cache_dir = Path(cache_dir)
        self.offline = offline
        self.minimum_interval = minimum_interval
        self.opener = opener or self._open
        self.clock, self.sleep = clock, sleep
        self._last = None
        self.requests = 0

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
        if self._last is not None:
            wait = self.minimum_interval - (self.clock() - self._last)
            if wait > 0:
                self.sleep(wait)
        self._last = self.clock()
        body = self.opener(url)
        self.requests += 1
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
                # 429/5xx: back off and retry; anything else is a real failure.
                if error.code not in (429, 500, 502, 503, 504) or attempt == 3:
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
