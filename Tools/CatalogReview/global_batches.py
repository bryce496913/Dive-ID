#!/usr/bin/env python3
"""Batch review of the Global pack: read every flagged record plus a seeded random sample.

`prepare` writes, for one batch of about 250 records:
- a manifest listing every speciesID, its reviewedContentFingerprint and whether it is
  flagged (risk flags; all read), sampled (30 unflagged records chosen with a recorded
  seed; all read) or unread, plus the manifest's own SHA-256;
- an HTML review page showing every published field and source link of the flagged
  and sampled records.

`page` re-renders the page of an existing manifest. `record` turns the reviewer's verbatim decision for one manifest hash into an overlay in
the Data/CatalogReview/BryceReview2026-10-12.json schema. It never infers a decision:
the outcome, exclusions and rejections are explicit arguments, and the decision text
is stored verbatim. Records the reviewer read get reviewMethod "individually-reviewed";
the rest "sample-approved". Any reported error in a sampled record rejects the whole
batch; regenerate it with a new seed after fixing.

`approved_reviews` is what publish_global.py applies. It fails closed: only the newest
manifest of each batch counts, its overlay must approve it, and a record is approved
only while its current content still has the fingerprint in that manifest.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import random
import re
import secrets
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
from catalog_review import PUBLICATION_FIELDS, content_fingerprint  # noqa: E402

SCHEMA_VERSION = 1
SAMPLE_SIZE = 30
PACK = REPO / "DiveID/Resources/IdentificationPacks/Global"
RISK_REPORT = REPO / "Data/GlobalMarine/FishBase/RiskReport.json"
BATCHES = REPO / "Data/CatalogReview/GlobalBatches"
PAGES = REPO / "Reports/GlobalReview"
METHODS = {"flagged": "individually-reviewed", "sampled": "individually-reviewed", "unread": "sample-approved"}
SAMPLING = "random.Random(seed).sample(sorted unflagged speciesIDs, min(30, count)) in CPython 3"
HASH = re.compile(r"(?:sha256:)?([0-9a-f]{64})")


class ReviewError(ValueError):
    pass


def canonical_sha256(document):
    return hashlib.sha256(json.dumps(document, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def manifest_hash(manifest):
    return canonical_sha256({k: v for k, v in manifest.items() if k != "manifestSHA256"})


def batch_name(batch):
    return f"batch-{batch:02d}"


def build_manifest(records, risk, batch, seed, generation, pack_metadata, member_ids=None, batch_id=None, rereview_of=None):
    """member_ids/batch_id select a re-review batch instead of a numbered batch."""
    batch_id = batch_id or batch_name(batch)
    members = sorted((r for r in records if (r["id"] in member_ids if member_ids is not None else risk.get(r["id"], {}).get("batch") == batch)),
                     key=lambda r: r["id"])
    if not members:
        raise ReviewError(f"{batch_id} has no records in the pack")
    # Records absent from the FishBase risk report (the carried Caribbean records) have no flags.
    flagged = {r["id"] for r in members if risk.get(r["id"], {}).get("flags")}
    unflagged = sorted(r["id"] for r in members if r["id"] not in flagged)
    sampled = set(random.Random(seed).sample(unflagged, min(SAMPLE_SIZE, len(unflagged))))
    entries = [{"speciesID": r["id"], "commonName": r["commonName"], "scientificName": r["scientificName"],
                "reviewedContentFingerprint": content_fingerprint(r),
                "selection": "flagged" if r["id"] in flagged else "sampled" if r["id"] in sampled else "unread",
                "riskScore": risk.get(r["id"], {}).get("score", 0), "flags": risk.get(r["id"], {}).get("flags", [])} for r in members]
    manifest = {"schemaVersion": SCHEMA_VERSION, "batchID": batch_id, "generation": generation,
                "pack": pack_metadata["id"], "packVersion": pack_metadata["packVersion"], "seed": seed,
                "sampleSize": len(sampled), "sampling": SAMPLING,
                "flaggedDefinition": "a risk flag in Data/GlobalMarine/FishBase/RiskReport.json",
                "counts": {s: sum(e["selection"] == s for e in entries) for s in ("flagged", "sampled", "unread")},
                "records": entries}
    if rereview_of:
        manifest["rereviewOf"] = rereview_of
    manifest["manifestSHA256"] = manifest_hash(manifest)
    return manifest


def changed_approvals(records, root, batch_id):
    """Records an approved generation of batch_id covered whose content has changed since:
    they lost their approval and need re-review. Unchanged records keep theirs."""
    manifests, overlays = load_manifests(root), load_overlays(root)
    history = _batch_history(manifests, batch_id)
    if not history:
        raise ReviewError(f"no manifest for {batch_id}")
    latest = history[-1]
    _, overlay = overlays.get(latest["manifestSHA256"], (None, None))
    if not overlay or overlay["decision"] != "approved":
        raise ReviewError(f"{batch_id} generation {latest['generation']} is not approved; nothing to re-review")
    current = {r["id"]: content_fingerprint(r) for r in records}
    changed = sorted(item["speciesID"] for item in overlay["records"] if current.get(item["speciesID"]) != item["reviewedContentFingerprint"])
    return changed, {"batchID": batch_id, "generation": latest["generation"], "manifestSHA256": latest["manifestSHA256"]}


def load_manifests(root):
    """All manifests under root, keyed by hash. A manifest whose content no longer
    matches its own SHA-256 is an error, never skipped."""
    manifests = {}
    for path in sorted(Path(root).glob("batch-*/manifest-*.json")):
        manifest = json.loads(path.read_text())
        if manifest.get("manifestSHA256") != manifest_hash(manifest):
            raise ReviewError(f"{path}: manifest content does not match its manifestSHA256")
        manifests[manifest["manifestSHA256"]] = (path, manifest)
    return manifests


def load_overlays(root):
    overlays = {}
    for path in sorted(Path(root).glob("batch-*/*Review*.json")):
        overlay = json.loads(path.read_text())
        key = overlay.get("batchManifestSHA256")
        if key in overlays:
            raise ReviewError(f"two decisions recorded for manifest {key}: {overlays[key][0]} and {path}")
        overlays[key] = (path, overlay)
    return overlays


def _batch_history(manifests, batch_id):
    return sorted((m for _, m in manifests.values() if m["batchID"] == batch_id), key=lambda m: m["generation"])


def _json_text(document):
    return json.dumps(document, indent=2, ensure_ascii=False) + "\n"


def _write_new(path, text):
    if path.exists():
        raise ReviewError(f"{path} already exists; it is never overwritten")
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text)
    temp.replace(path)


NAME = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


def prepare(batch, seed=None, force_new=False, root=BATCHES, pages=PAGES, pack=PACK, risk_path=RISK_REPORT, rereview=False,
            members=None, name=None):
    """rereview: a separate batch (batch-NN-rereview) of only the records whose approved
    content in batch-NN changed. batch-NN itself is left alone, so its unchanged records
    keep their approval.

    members/name: a named batch (batch-<name>) of exactly these species IDs, for example
    the records of one regional pack. batch is then ignored. With 30 or fewer unflagged
    records every record is sampled, so the page shows them all."""
    records = json.loads((Path(pack) / "Creatures.json").read_text())
    metadata = json.loads((Path(pack) / "PackManifest.json").read_text())
    risk = json.loads(Path(risk_path).read_text())["records"]
    member_ids, batch_id, rereview_of = None, batch_name(batch) if batch is not None else None, None
    if members is not None:
        if rereview:
            raise ReviewError("a named batch cannot also be a re-review")
        if not name or not NAME.fullmatch(name) or re.fullmatch(r"\d+(?:-rereview)?", name):
            raise ReviewError("a named batch needs --name of lowercase words joined by hyphens, not a batch number")
        member_ids, batch_id = set(members), f"batch-{name}"
        missing = sorted(member_ids - {r["id"] for r in records})
        if missing:
            raise ReviewError(f"not in the pack: {', '.join(missing)}")
    elif batch is None:
        raise ReviewError("prepare needs --batch, or --name with --ids")
    if rereview:
        changed, rereview_of = changed_approvals(records, root, batch_name(batch))
        if not changed:
            raise ReviewError(f"no approved record in {batch_name(batch)} has changed; nothing to re-review")
        member_ids, batch_id = set(changed), f"{batch_name(batch)}-rereview"
    manifests, overlays = load_manifests(root), load_overlays(root)
    history = _batch_history(manifests, batch_id)
    if history:
        latest = history[-1]
        decision = overlays.get(latest["manifestSHA256"], (None, {}))[1].get("decision")
        if decision != "rejected" and not force_new:
            state = "approved" if decision == "approved" else "awaiting a decision"
            raise ReviewError(f"{batch_id} generation {latest['generation']} is {state}; "
                              "a new generation replaces it (pass --force-new to do so deliberately)")
        if seed is not None and seed in {m["seed"] for m in history}:
            raise ReviewError(f"seed {seed} was already used for {batch_id}; a regenerated batch needs a new seed")
    used = {m["seed"] for m in history}
    while seed is None or seed in used:
        seed = secrets.randbelow(2 ** 63)
    manifest = build_manifest(records, risk, batch, seed, len(history) + 1, metadata, member_ids, batch_id, rereview_of)
    short = manifest["manifestSHA256"][:12]
    manifest_path = Path(root) / manifest["batchID"] / f"manifest-g{manifest['generation']}-{short}.json"
    page_path = Path(pages) / f"{manifest['batchID']}-g{manifest['generation']}-{short}.html"
    by_id = {r["id"]: r for r in records}
    _write_new(manifest_path, _json_text(manifest))
    page_path.parent.mkdir(parents=True, exist_ok=True)
    page_path.write_text(review_page(manifest, by_id))
    return manifest, manifest_path, page_path


def render_page(manifest_sha256, root=BATCHES, pages=PAGES, pack=PACK):
    """Re-render the review page of an existing manifest (same seed and sample)."""
    match = HASH.fullmatch(manifest_sha256.strip())
    manifests = load_manifests(root)
    if not match or match.group(1) not in manifests:
        raise ReviewError(f"no manifest with SHA-256 {manifest_sha256}")
    manifest = manifests[match.group(1)][1]
    by_id = {r["id"]: r for r in json.loads((Path(pack) / "Creatures.json").read_text())}
    page_path = Path(pages) / f"{manifest['batchID']}-g{manifest['generation']}-{manifest['manifestSHA256'][:12]}.html"
    page_path.parent.mkdir(parents=True, exist_ok=True)
    page_path.write_text(review_page(manifest, by_id))
    return page_path


def _parse_notes(items, label):
    notes = {}
    for item in items or []:
        species_id, separator, note = item.partition("=")
        if not separator or not note.strip():
            raise ReviewError(f"--{label} needs ID=note; got {item!r}")
        notes[species_id.strip()] = note.strip()
    return notes


def _current_commit():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def record(manifest_sha256, reviewer, decision_text, outcome, review_date=None, excludes=(), rejects=(), reason=None,
           root=BATCHES, pack=PACK, commit=None):
    """Write the overlay for one manifest from the reviewer's own decision. Returns (path, overlay)."""
    match = HASH.fullmatch(manifest_sha256.strip())
    if not match:
        raise ReviewError("the manifest hash must be 64 hex characters")
    if not reviewer or not reviewer.strip():
        raise ReviewError("the reviewer identity is required")
    if not decision_text or not decision_text.strip():
        raise ReviewError("the reviewer's verbatim decision text is required")
    if outcome not in ("approve", "reject"):
        raise ReviewError("outcome must be approve or reject")
    review_date = review_date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    datetime.strptime(review_date, "%Y-%m-%d")
    manifests, overlays = load_manifests(root), load_overlays(root)
    key = match.group(1)
    if key not in manifests:
        raise ReviewError(f"no manifest with SHA-256 {key}")
    if key in overlays:
        raise ReviewError(f"a decision is already recorded for manifest {key}: {overlays[key][0]}")
    _, manifest = manifests[key]
    latest = _batch_history(manifests, manifest["batchID"])[-1]
    if latest["manifestSHA256"] != key:
        raise ReviewError(f"manifest {key} was superseded by generation {latest['generation']} of {manifest['batchID']}")

    entries = {e["speciesID"]: e for e in manifest["records"]}
    excluded, rejected = _parse_notes(excludes, "exclude"), _parse_notes(rejects, "reject")
    unknown = sorted((set(excluded) | set(rejected)) - set(entries))
    if unknown:
        raise ReviewError(f"not in this batch: {', '.join(unknown)}")
    both = sorted(set(excluded) & set(rejected))
    if both:
        raise ReviewError(f"both excluded and rejected: {', '.join(both)}")
    sample_errors = [{"speciesID": i, "note": n} for i, n in sorted(rejected.items()) if entries[i]["selection"] == "sampled"]
    if outcome == "reject" and not (reason and reason.strip()) and not sample_errors:
        raise ReviewError("a rejected batch needs --reason or a rejected sampled record")

    current = {r["id"]: content_fingerprint(r) for r in json.loads((Path(pack) / "Creatures.json").read_text())}
    sources = {r["id"]: [s["sourceURL"] for s in r.get("dataSources", [])] for r in json.loads((Path(pack) / "Creatures.json").read_text())}
    approved = outcome == "approve" and not sample_errors
    held = []
    for species_id, entry in sorted(entries.items()):
        note = excluded.get(species_id) or rejected.get(species_id)
        state = "excluded" if species_id in excluded else "rejected" if species_id in rejected else None
        if state is None and current.get(species_id) != entry["reviewedContentFingerprint"]:
            state, note = "stale", "content changed after the manifest was generated; not approved"
        if state:
            held.append({"speciesID": species_id, "reviewedContentFingerprint": entry["reviewedContentFingerprint"],
                         "selection": entry["selection"], "outcome": state, "note": note})
    held_ids = {h["speciesID"] for h in held}
    overlay = {
        "schemaVersion": 1,
        "reviewerIdentity": reviewer.strip(),
        "reviewDate": review_date,
        "datePrecision": "day; overlay UTC midnight represents the supplied calendar date, not an asserted time of review",
        "decision": "approved" if approved else "rejected",
        "provenance": "Recorded by Tools/CatalogReview/global_batches.py record from decision text the reviewer typed for this manifest hash; the tool never infers a decision.",
        "reviewReference": f"Data/CatalogReview/GlobalBatches/{manifest['batchID']}/ (manifest sha256:{key})",
        "verbatimDecision": decision_text,
        "batchID": manifest["batchID"], "generation": manifest["generation"],
        "batchManifestSHA256": key, "seed": manifest["seed"],
        "records": [] if not approved else [
            {"speciesID": i, "reviewedContentFingerprint": e["reviewedContentFingerprint"], "reviewMethod": METHODS[e["selection"]],
             "resolvedQuestions": [], "sourceReferences": sources.get(i, [])}
            for i, e in sorted(entries.items()) if i not in held_ids],
        "heldRecords": held,
        "rejection": None if approved else {
            "reason": (reason or "").strip() or "an error was reported in a sampled record; batch rule: the batch is not approved",
            "sampleErrors": sample_errors,
            "next": "fix the records, rebuild the pack, then regenerate this batch with a new seed"},
        "reviewedCommit": commit if commit is not None else _current_commit(),
    }
    path = Path(root) / manifest["batchID"] / f"{reviewer.strip()}Review{review_date}-{manifest['batchID']}-g{manifest['generation']}.json"
    _write_new(path, _json_text(overlay))
    return path, overlay


def approved_reviews(records, root=BATCHES):
    """{speciesID: review} for records an approval still covers, and a report of what was withheld."""
    manifests, overlays = load_manifests(root), load_overlays(root)
    for key, (path, _) in overlays.items():
        if key not in manifests:
            raise ReviewError(f"{path}: decision for an unknown manifest {key}")
    current = {r["id"]: content_fingerprint(r) for r in records}
    reviews, report = {}, {"approvedBatches": [], "pendingBatches": [], "rejectedBatches": [], "staleRecords": []}
    for batch_id in sorted({m["batchID"] for _, m in manifests.values()}):
        latest = _batch_history(manifests, batch_id)[-1]
        _, overlay = overlays.get(latest["manifestSHA256"], (None, None))
        label = f"{batch_id} g{latest['generation']}"
        if overlay is None:
            report["pendingBatches"].append(label)
            continue
        if overlay["decision"] != "approved":
            report["rejectedBatches"].append(label)
            continue
        report["approvedBatches"].append(label)
        listed = {e["speciesID"]: e["reviewedContentFingerprint"] for e in latest["records"]}
        for item in overlay["records"]:
            species_id, fingerprint = item["speciesID"], item["reviewedContentFingerprint"]
            if listed.get(species_id) != fingerprint or current.get(species_id) != fingerprint:
                report["staleRecords"].append(species_id)
                continue
            method = item["reviewMethod"]
            how = ("individually reviewed" if method == "individually-reviewed" else
                   "not individually read; approved because every flagged record and a seeded random sample of "
                   f"{latest['sampleSize']} records in the batch passed review")
            reviews[species_id] = {
                "status": "verified",
                "reviewerNotes": f"{overlay['reviewerIdentity']} approved Global {batch_id} generation {latest['generation']} "
                                 f"(manifest sha256:{latest['manifestSHA256']}) on {overlay['reviewDate']}: "
                                 f"\"{overlay['verbatimDecision']}\". This record: {how}.",
                "reviewDate": overlay["reviewDate"] + "T00:00:00Z",
                "verifiedBy": overlay["reviewerIdentity"],
                "reviewMethod": method,
            }
    report["staleRecords"].sort()
    return reviews, report


# ---- Review page ----------------------------------------------------------------

FIELD_LABELS = {
    "commonName": "Common name", "scientificName": "Scientific name", "aliases": "Other names", "categories": "Animal group",
    "colors": "Colours", "markings": "Markings", "bodyShapes": "Body shape", "habitats": "Habitats", "regions": "Regions",
    "behaviors": "Behaviour", "keywords": "Keywords", "minimumSizeCentimeters": "Minimum size (cm)",
    "maximumSizeCentimeters": "Maximum size (cm)", "minimumDepthMeters": "Minimum depth (m)", "maximumDepthMeters": "Maximum depth (m)",
    "summary": "Summary", "distinguishingFeatures": "Distinguishing features", "typicalHabitat": "Typical habitat",
    "geographicRange": "Geographic range", "cautions": "Cautions", "regionalOccurrence": "Regional occurrence",
    "regionalOccurrenceNotes": "Occurrence notes", "subregions": "Subregions", "appearanceVariants": "Life-stage variants",
    "similarSpecies": "Similar species", "taxonomy": "Taxonomy", "measurements": "Measurements", "tailShape": "Tail shape",
    "mouthAndHeadShape": "Head and mouth", "finAndSpineClues": "Fin and spine clues", "dataSources": "Sources"}


def _value_html(value):
    if isinstance(value, list):
        if not value:
            return ""
        if all(isinstance(v, str) for v in value):
            return "<ul>" + "".join(f"<li>{html.escape(v)}</li>" for v in value) + "</ul>"
        return "<ul>" + "".join(f"<li><code>{html.escape(json.dumps(v, ensure_ascii=False))}</code></li>" for v in value) + "</ul>"
    if isinstance(value, dict):
        return "<dl class='nested'>" + "".join(f"<dt>{html.escape(k)}</dt><dd>{html.escape(str(v))}</dd>" for k, v in value.items() if v not in (None, "", [])) + "</dl>"
    return html.escape(str(value))


def _record_html(entry, record):
    if content_fingerprint(record) != entry["reviewedContentFingerprint"]:
        return (f"<article id='{entry['speciesID']}'><h3>{html.escape(entry['commonName'])}</h3><p class='flag'>Content changed after "
                "this manifest was generated; it cannot be approved from this page. Regenerate the batch.</p></article>")
    links = []
    for source in record.get("dataSources", []):
        links.append(f"<a href='{html.escape(source['sourceURL'])}'>{html.escape(source.get('sourceName', 'Source'))}</a>"
                     + (f" — {html.escape(source['citationReference'])}" if source.get("citationReference") else ""))
    rows = []
    for field in PUBLICATION_FIELDS:
        value = record.get(field)
        if value in (None, "", [], {}) or field == "dataSources":
            continue
        if field == "appearanceVariants":
            value = [v.get("description") or v.get("lifeStage") for v in value]
        rows.append(f"<tr><th>{html.escape(FIELD_LABELS.get(field, field))}</th><td>{_value_html(value)}</td></tr>")
    flags = "".join(f"<span class='flag'>{html.escape(f)}</span>" for f in entry["flags"]) or "<span class='muted'>no flags</span>"
    used = sorted({f for source in record.get("dataSources", []) for f in source.get("sourceFields", [])})
    if used:
        links.append("<span class='muted'>source fields: " + html.escape(", ".join(used)) + "</span>")
    return (f"<article id='{entry['speciesID']}'><h3>{html.escape(entry['commonName'])} "
            f"<em>{html.escape(entry['scientificName'])}</em></h3>"
            f"<p class='meta'>Risk score {entry['riskScore']} · {flags}<br><code>{entry['speciesID']}</code> · "
            f"<code>{entry['reviewedContentFingerprint']}</code></p>"
            f"<p class='sources'>{' · '.join(links)}</p><table>{''.join(rows)}</table></article>")


def review_page(manifest, by_id):
    entries = manifest["records"]
    flagged = sorted((e for e in entries if e["selection"] == "flagged"), key=lambda e: (-e["riskScore"], e["commonName"].lower(), e["speciesID"]))
    sampled = sorted((e for e in entries if e["selection"] == "sampled"), key=lambda e: (e["commonName"].lower(), e["speciesID"]))
    unread = sorted((e for e in entries if e["selection"] == "unread"), key=lambda e: (e["commonName"].lower(), e["speciesID"]))
    key = manifest["manifestSHA256"]
    title = f"Global {manifest['batchID']} review (generation {manifest['generation']})"
    origin = manifest.get("rereviewOf")
    rereview = (f"<p><strong>Re-review.</strong> These {len(entries)} records were approved in {html.escape(origin['batchID'])} "
                f"generation {origin['generation']} and their content has changed since, so that approval no longer covers them. "
                "Records in that batch whose content did not change keep their approval.</p>") if origin else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>
:root {{ --bg:#fbfbf8; --fg:#1d232a; --muted:#5b6670; --line:#d9dde1; --flag:#9c3d10; --flagbg:#fbe9df; --card:#fff; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#14181c; --fg:#e7eaee; --muted:#9aa5ae; --line:#2c343b; --flag:#ffb38a; --flagbg:#3a2418; --card:#1b2026; }} }}
body {{ margin:0 auto; max-width:960px; padding:16px; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui, sans-serif; }}
h1 {{ font-size:1.5rem; }} h2 {{ margin-top:2.5rem; border-bottom:1px solid var(--line); }}
article {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:12px 16px; margin:16px 0; }}
h3 {{ margin:0 0 4px; }} h3 em {{ font-weight:normal; color:var(--muted); }}
.meta, .muted {{ color:var(--muted); font-size:.85rem; overflow-wrap:anywhere; }}
.flag {{ display:inline-block; background:var(--flagbg); color:var(--flag); border-radius:4px; padding:0 6px; margin-right:4px; }}
table {{ width:100%; border-collapse:collapse; table-layout:fixed; }} th, td {{ text-align:left; vertical-align:top; padding:4px 8px 4px 0; border-top:1px solid var(--line); }}
th {{ width:11rem; font-weight:600; }} td {{ overflow-wrap:anywhere; }} ul {{ margin:0; padding-left:1.1rem; }} code {{ font-size:.8rem; overflow-wrap:anywhere; }}
dl.nested {{ margin:0; display:grid; grid-template-columns:max-content 1fr; gap:0 8px; }} dl.nested dd {{ margin:0; }}
.box {{ border:1px solid var(--line); border-radius:8px; padding:12px 16px; background:var(--card); }}
a {{ color:inherit; }}
@media (max-width:600px) {{ th, td {{ display:block; width:auto; }} th {{ padding-bottom:0; }} td {{ border-top:0; padding-top:0; }} }}
</style></head><body>
<h1>{html.escape(title)}</h1>
<div class="box">
<p><strong>Manifest SHA-256:</strong> <code>{key}</code><br>
Pack {html.escape(manifest['pack'])} v{manifest['packVersion']} · {len(entries)} records · {len(flagged)} flagged · {len(sampled)} sampled · {len(unread)} not shown<br>
Sample seed <code>{manifest['seed']}</code> ({html.escape(manifest['sampling'])})</p>
{rereview}<p><strong>Batch rule.</strong> Read every record below. If any sampled record has an error, the whole batch is not
approved; it is fixed and regenerated with a new seed. Records you read are recorded as individually reviewed;
the {len(unread)} records not shown are recorded as sample-approved. You may exclude or reject specific IDs with a note.
To decide, reply with your decision in your own words and this manifest hash.</p>
</div>
<h2>Flagged records ({len(flagged)}), highest risk first</h2>
{''.join(_record_html(e, by_id[e['speciesID']]) for e in flagged) or '<p class="muted">No flagged records in this batch.</p>'}
<h2>Random sample of unflagged records ({len(sampled)})</h2>
{''.join(_record_html(e, by_id[e['speciesID']]) for e in sampled)}
<h2>Not shown: sample-approved if the batch is approved ({len(unread)})</h2>
<p class="muted">{', '.join(html.escape(e['commonName']) for e in unread)}</p>
</body></html>
"""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare", help="write a batch manifest and its review page")
    p.add_argument("--batch", type=int, help="a numbered batch (from RiskReport.json)")
    p.add_argument("--name", help="with --ids: a named batch, batch-NAME")
    p.add_argument("--ids", help="with --name: comma-separated species IDs")
    p.add_argument("--seed", type=int, help="default: a fresh random seed, recorded in the manifest")
    p.add_argument("--force-new", action="store_true", help="replace an undecided or approved generation")
    p.add_argument("--rereview", action="store_true", help="only the batch's approved records whose content changed, as batch-NN-rereview")
    g = commands.add_parser("page", help="re-render the review page of an existing manifest")
    g.add_argument("--manifest-sha256", required=True)
    r = commands.add_parser("record", help="record the reviewer's decision for one manifest")
    r.add_argument("--manifest-sha256", required=True)
    r.add_argument("--reviewer", required=True)
    r.add_argument("--decision-text", required=True, help="the reviewer's decision, verbatim")
    r.add_argument("--outcome", choices=["approve", "reject"], required=True)
    r.add_argument("--date", help="YYYY-MM-DD; default today (UTC)")
    r.add_argument("--exclude", action="append", metavar="ID=NOTE", help="hold a record out of approval")
    r.add_argument("--reject", action="append", metavar="ID=NOTE", help="a record with an error; a sampled one rejects the batch")
    r.add_argument("--reason", help="why the batch is rejected")
    args = parser.parse_args(argv)
    try:
        if args.command == "prepare":
            members = [i.strip() for i in args.ids.split(",") if i.strip()] if args.ids else None
            if (members is None) != (args.name is None):
                raise ReviewError("--name and --ids go together")
            manifest, manifest_path, page_path = prepare(args.batch, args.seed, args.force_new, rereview=args.rereview,
                                                         members=members, name=args.name)
            print(json.dumps({"manifest": str(manifest_path.relative_to(REPO)), "page": str(page_path.relative_to(REPO)),
                              "manifestSHA256": manifest["manifestSHA256"], "seed": manifest["seed"], "counts": manifest["counts"]}, indent=2))
        elif args.command == "page":
            print(render_page(args.manifest_sha256).relative_to(REPO))
        else:
            path, overlay = record(args.manifest_sha256, args.reviewer, args.decision_text, args.outcome, args.date,
                                   args.exclude, args.reject, args.reason)
            print(json.dumps({"overlay": str(path.relative_to(REPO)), "decision": overlay["decision"],
                              "approvedRecords": len(overlay["records"]), "heldRecords": len(overlay["heldRecords"]),
                              "rejection": overlay["rejection"]}, indent=2, ensure_ascii=False))
    except ReviewError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
