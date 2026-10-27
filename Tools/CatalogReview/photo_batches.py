#!/usr/bin/env python3
"""Review of species photos in batches, like records (global_batches.py).

`prepare` writes, for a named batch of species:
- a manifest listing every selected photo of those species from
  Data/SpeciesPhotos/PhotoManifest.json with its photoFingerprint (attribution, licence,
  photo URL and the thumbnail's SHA-256), plus the manifest's own SHA-256;
- an HTML review page showing each photo (its bundle thumbnail) beside the species'
  common name, scientific name and distinguishing features, with its attribution and links.

Every photo is shown and read; there is no sampling. `record` turns the reviewer's
verbatim decision for one manifest hash into an overlay. It never infers a decision: the
outcome and each rejected photo are explicit arguments, and the decision text is stored
verbatim.

`approved_photos` is what publish_global.py applies. It fails closed: only the newest
manifest of each batch counts, its overlay must approve it, and a photo is approved only
while its current fingerprint (in the photo manifest and thumbnail index) still matches
the one reviewed. Nothing else puts a photo in the app.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
from global_batches import (HASH, NAME, PACK, ReviewError, _current_commit, _json_text, _parse_notes,  # noqa: E402
                            _write_new, canonical_sha256, manifest_hash)

SCHEMA_VERSION = 1
PHOTO_MANIFEST = REPO / "Data/SpeciesPhotos/PhotoManifest.json"
THUMBNAILS = REPO / "Data/SpeciesPhotos/Thumbnails"
BATCHES = REPO / "Data/CatalogReview/PhotoBatches"
PAGES = REPO / "Reports/PhotoReview"
FINGERPRINT_FIELDS = ("photoID", "speciesID", "photoURL", "sourcePageURL", "observationID", "taxonID", "creatorName",
                      "licenceCode", "licenseName", "licenseURL", "sourceName")


def thumbnail_index(thumbnails=THUMBNAILS):
    path = Path(thumbnails) / "Thumbnails.json"
    return json.loads(path.read_text()) if path.exists() else {}


def photo_fingerprint(photo, thumbnail=None):
    """What the reviewer saw and approved: the attribution and, when there is one, the exact
    thumbnail bytes that would be bundled."""
    payload = {field: photo.get(field) for field in FINGERPRINT_FIELDS}
    payload["thumbnailSHA256"] = thumbnail["sha256"] if thumbnail else None
    return "sha256:" + canonical_sha256(payload)


def load_manifests(root):
    manifests = {}
    for path in sorted(Path(root).glob("*/manifest-*.json")):
        manifest = json.loads(path.read_text())
        if manifest.get("manifestSHA256") != manifest_hash(manifest):
            raise ReviewError(f"{path}: manifest content does not match its manifestSHA256")
        manifests[manifest["manifestSHA256"]] = (path, manifest)
    return manifests


def load_overlays(root):
    overlays = {}
    for path in sorted(Path(root).glob("*/*Review*.json")):
        overlay = json.loads(path.read_text())
        key = overlay.get("batchManifestSHA256")
        if key in overlays:
            raise ReviewError(f"two decisions recorded for manifest {key}: {overlays[key][0]} and {path}")
        overlays[key] = (path, overlay)
    return overlays


def newest(manifests, batch_id):
    history = sorted((m for _, m in manifests.values() if m["batchID"] == batch_id), key=lambda m: m["generation"])
    return history[-1] if history else None


def prepare(batch_id, species_ids, root=BATCHES, pages=PAGES, photo_manifest=PHOTO_MANIFEST, thumbnails=THUMBNAILS, pack=PACK,
            require_thumbnails=True):
    """Write generation N+1 of a batch and its review page. Returns (manifest path, page path, manifest)."""
    if not NAME.fullmatch(batch_id or ""):
        raise ReviewError("the batch ID must be lower-case words joined by hyphens, e.g. caribbean-8")
    wanted = {s.upper() for s in species_ids}
    if not wanted:
        raise ReviewError("name at least one species")
    document = json.loads(Path(photo_manifest).read_text())
    index = thumbnail_index(thumbnails)
    photos = sorted((p for p in document["photos"] if p["speciesID"].upper() in wanted), key=lambda p: (p["speciesID"], p["rank"]))
    missing = sorted(wanted - {p["speciesID"].upper() for p in photos})
    if missing:
        raise ReviewError(f"no selected photo for: {', '.join(missing)}")
    unthumbed = [p["photoID"] for p in photos if p["photoID"] not in index]
    if require_thumbnails and unthumbed:
        raise ReviewError(f"make thumbnails first (Tools/SpeciesPhotos/thumbnails.py): {', '.join(unthumbed)}")
    manifests = load_manifests(root)
    previous = newest(manifests, batch_id)
    manifest = {
        "schemaVersion": SCHEMA_VERSION, "batchID": batch_id, "generation": (previous["generation"] + 1) if previous else 1,
        "photoManifestSHA256": canonical_sha256(document),
        "photos": [{"photoID": p["photoID"], "speciesID": p["speciesID"], "commonName": p["commonName"],
                    "scientificName": p["scientificName"], "rank": p["rank"],
                    "thumbnail": index[p["photoID"]]["fileName"] if p["photoID"] in index else None,
                    "photoFingerprint": photo_fingerprint(p, index.get(p["photoID"]))} for p in photos],
    }
    manifest["manifestSHA256"] = manifest_hash(manifest)
    path = Path(root) / batch_id / f"manifest-g{manifest['generation']}.json"
    _write_new(path, _json_text(manifest))
    page = render_page(manifest, document, index, pages, thumbnails, pack)
    return path, page, manifest


def render_page(manifest, document, index, pages=PAGES, thumbnails=THUMBNAILS, pack=PACK):
    by_photo = {p["photoID"]: p for p in document["photos"]}
    records = {r["id"]: r for r in json.loads((Path(pack) / "Creatures.json").read_text())}
    page = Path(pages) / f"{manifest['batchID']}-g{manifest['generation']}-{manifest['manifestSHA256'][:12]}.html"
    page.parent.mkdir(parents=True, exist_ok=True)
    page.write_text(review_page(manifest, by_photo, records, Path(os.path.relpath(Path(thumbnails), page.parent))))
    return page


def _photo_html(entry, photo, record, thumbnail_dir):
    image = (thumbnail_dir / entry["thumbnail"]).as_posix() if entry["thumbnail"] else photo["photoURL"]
    features = "".join(f"<li>{html.escape(f)}</li>" for f in (record or {}).get("distinguishingFeatures", []))
    colours = ", ".join((record or {}).get("colors", []))
    markings = ", ".join((record or {}).get("markings", []))
    return f"""<article id="{html.escape(entry['photoID'])}">
<img src="{html.escape(image)}" alt="Photo {entry['rank']} offered for {html.escape(entry['commonName'])}" loading="lazy">
<div><h3>{html.escape(entry['commonName'])} <em>{html.escape(entry['scientificName'])}</em></h3>
<p class="meta">Photo {entry['rank']} · <code>{html.escape(entry['photoID'])}</code></p>
<h4>Distinguishing features</h4><ul>{features or '<li class="muted">none recorded</li>'}</ul>
<p class="muted">Colours: {html.escape(colours) or '—'} · Markings: {html.escape(markings) or '—'}</p>
<p><strong>{html.escape(photo['creatorName'])}</strong> · {html.escape(photo['licenseName'])} · {html.escape(photo['sourceName'])}<br>
<a href="{html.escape(photo['sourcePageURL'])}">Photo page</a> · <a href="{html.escape(photo['observationURL'])}">Observation</a>
(research grade, observed {html.escape(photo.get('observedOn') or 'date not given')})</p></div>
</article>"""


def review_page(manifest, by_photo, records, thumbnail_dir):
    entries = manifest["photos"]
    title = f"Species photos {manifest['batchID']} review (generation {manifest['generation']})"
    cards = "".join(_photo_html(e, by_photo[e["photoID"]], records.get(e["speciesID"]), thumbnail_dir) for e in entries)
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
:root {{ --bg:#fbfbf8; --fg:#1d232a; --muted:#5b6670; --line:#d9dde1; --card:#fff; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#14181c; --fg:#e7eaee; --muted:#9aa5ae; --line:#2c343b; --card:#1b2026; }} }}
body {{ margin:0 auto; max-width:1040px; padding:16px; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, sans-serif; }}
article {{ display:grid; grid-template-columns:400px 1fr; gap:16px; background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px; margin:16px 0; }}
img {{ width:100%; max-width:400px; height:auto; border-radius:6px; background:var(--line); }}
h3 {{ margin:0 0 4px; }} h3 em {{ font-weight:normal; color:var(--muted); }} h4 {{ margin:8px 0 2px; }}
.meta, .muted {{ color:var(--muted); font-size:.85rem; overflow-wrap:anywhere; }} code {{ font-size:.8rem; }}
.box {{ border:1px solid var(--line); border-radius:8px; padding:12px 16px; background:var(--card); }} ul {{ margin:0; padding-left:1.1rem; }}
a {{ color:inherit; }}
@media (max-width:760px) {{ article {{ grid-template-columns:1fr; }} }}
</style></head><body>
<h1>{html.escape(title)}</h1>
<div class="box"><p><strong>Manifest SHA-256:</strong> <code>{manifest['manifestSHA256']}</code><br>
{len(entries)} photos of {len({e['speciesID'] for e in entries})} species. Each image is the exact thumbnail that would be bundled.</p>
<p><strong>For each photo, check:</strong> it shows this species, in the colours a diver would see (compare the features
listed; note a juvenile or other life stage); it is a clear, preferably lateral, whole-animal underwater photo; and the
photographer and licence match its photo page. Note anything else that matters to you, such as a watermark or a hand in
the frame. Approving puts the species' first approved photo on its page and in results, credited as shown. Reject any
photo with a note; the rest of the batch can still be approved.</p>
<p>To decide, reply with your decision in your own words and this manifest hash.</p></div>
{cards}
</body></html>
"""


def record(manifest_sha256, reviewer, decision_text, outcome, review_date=None, rejects=(), reason=None, root=BATCHES,
           commit=None):
    """Write the overlay for one manifest from the reviewer's own decision. Returns (path, overlay)."""
    match = HASH.fullmatch((manifest_sha256 or "").strip())
    if not match:
        raise ReviewError("the manifest hash must be 64 hex characters")
    if not reviewer or not reviewer.strip():
        raise ReviewError("the reviewer identity is required")
    if not decision_text or not decision_text.strip():
        raise ReviewError("the reviewer's verbatim decision text is required")
    if outcome not in ("approve", "reject"):
        raise ReviewError("outcome must be approve or reject")
    if outcome == "reject" and not (reason and reason.strip()):
        raise ReviewError("a rejected batch needs --reason")
    review_date = review_date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    datetime.strptime(review_date, "%Y-%m-%d")
    manifests, overlays = load_manifests(root), load_overlays(root)
    key = match.group(1)
    if key not in manifests:
        raise ReviewError(f"no manifest with SHA-256 {key}")
    if key in overlays:
        raise ReviewError(f"a decision is already recorded for manifest {key}: {overlays[key][0]}")
    _, manifest = manifests[key]
    latest = newest(manifests, manifest["batchID"])
    if latest["manifestSHA256"] != key:
        raise ReviewError(f"manifest {key} was superseded by generation {latest['generation']} of {manifest['batchID']}")
    entries = {e["photoID"]: e for e in manifest["photos"]}
    rejected = _parse_notes(rejects, "reject")
    unknown = sorted(set(rejected) - set(entries))
    if unknown:
        raise ReviewError(f"not in this batch: {', '.join(unknown)}")
    approved = outcome == "approve"
    overlay = {
        "schemaVersion": SCHEMA_VERSION,
        "reviewerIdentity": reviewer.strip(),
        "reviewDate": review_date,
        "decision": "approved" if approved else "rejected",
        "provenance": "Recorded by Tools/CatalogReview/photo_batches.py record from decision text the reviewer typed for this manifest hash; the tool never infers a decision.",
        "verbatimDecision": decision_text,
        "batchID": manifest["batchID"], "generation": manifest["generation"], "batchManifestSHA256": key,
        "photos": [] if not approved else [
            {"photoID": i, "speciesID": e["speciesID"], "photoFingerprint": e["photoFingerprint"]}
            for i, e in sorted(entries.items()) if i not in rejected],
        "rejectedPhotos": [{"photoID": i, "speciesID": entries[i]["speciesID"], "note": n} for i, n in sorted(rejected.items())],
        "rejection": None if approved else {"reason": reason.strip()},
        "reviewedCommit": commit if commit is not None else _current_commit(),
    }
    path = Path(root) / manifest["batchID"] / f"{reviewer.strip()}Review{review_date}-{manifest['batchID']}-g{manifest['generation']}.json"
    _write_new(path, _json_text(overlay))
    return path, overlay


def approved_photos(photos, index, root=BATCHES):
    """({photoID: approval}, report) for the photos whose current fingerprint an approved,
    current batch decision covers. photos is the photo manifest's list; index the thumbnails."""
    manifests, overlays = load_manifests(root), load_overlays(root)
    current = {p["photoID"]: photo_fingerprint(p, index.get(p["photoID"])) for p in photos}
    approvals, stale, superseded = {}, [], []
    for key, (_, overlay) in sorted(overlays.items()):
        if key not in manifests:
            raise ReviewError(f"a decision names manifest {key}, which does not exist")
        manifest = manifests[key][1]
        if newest(manifests, manifest["batchID"])["manifestSHA256"] != key:
            superseded.append(manifest["batchID"] + f"-g{manifest['generation']}")
            continue
        if overlay["decision"] != "approved":
            continue
        reviewed = {e["photoID"]: e["photoFingerprint"] for e in manifest["photos"]}
        for entry in overlay["photos"]:
            photo_id = entry["photoID"]
            if reviewed.get(photo_id) != entry["photoFingerprint"]:
                raise ReviewError(f"{photo_id}: the decision's fingerprint is not the manifest's")
            if current.get(photo_id) != entry["photoFingerprint"]:
                stale.append(photo_id)
                continue
            approvals[photo_id] = {"reviewedBy": overlay["reviewerIdentity"], "reviewDate": overlay["reviewDate"],
                                   "batchID": manifest["batchID"], "manifestSHA256": key}
    return approvals, {"approvedPhotos": len(approvals), "stalePhotos": sorted(stale), "supersededDecisions": sorted(superseded)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare", help="write a photo batch manifest and its review page")
    p.add_argument("batch_id")
    p.add_argument("--species", nargs="+", required=True)
    r = commands.add_parser("record", help="record the reviewer's decision for one manifest")
    r.add_argument("manifest_sha256")
    r.add_argument("--reviewer", required=True)
    r.add_argument("--decision-text", required=True, help="the reviewer's decision, verbatim")
    r.add_argument("--outcome", required=True, choices=("approve", "reject"))
    r.add_argument("--review-date")
    r.add_argument("--reject", action="append", default=[], metavar="PHOTOID=NOTE")
    r.add_argument("--reason")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            path, page, manifest = prepare(args.batch_id, args.species)
            print(json.dumps({"manifest": str(path.relative_to(REPO)), "page": str(page.relative_to(REPO)),
                              "manifestSHA256": manifest["manifestSHA256"], "photos": len(manifest["photos"])}, indent=2))
        else:
            path, overlay = record(args.manifest_sha256, args.reviewer, args.decision_text, args.outcome, args.review_date,
                                   args.reject, args.reason)
            print(json.dumps({"overlay": str(path.relative_to(REPO)), "decision": overlay["decision"],
                              "approvedPhotos": len(overlay["photos"]), "rejectedPhotos": len(overlay["rejectedPhotos"])}, indent=2))
    except ReviewError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
