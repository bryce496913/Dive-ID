"""Plan the global merge: one UUID per accepted taxon, without changing an existing UUID.

Inputs: the app packs (existing records and their UUIDs), the intake crosswalk
(Data/GlobalMarine/IntakeCrosswalk.csv: each candidate's UUID, reusing a workbook
identity where one exists), and the taxon each input resolved to
(NameResolution.csv, keyed by FishBase/SeaLifeBase SpecCode).

For each accepted taxon the plan keeps exactly one UUID:
1. the existing app record's UUID, if there is one;
2. otherwise the one existing workbook identity among its candidates;
3. otherwise the first candidate's UUID in queue order.
Other UUIDs for the taxon are retired into the plan as aliases, never reassigned.

Conflicts stop the plan (exit status 2): two existing app records for one taxon, two
distinct workbook identities for one taxon, or one UUID claimed by two taxa. Each is
listed in the report for a decision. Unresolved or ambiguous inputs are listed, not merged.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
FIELDS = ["inputKind", "inputID", "pack", "inputName", "inputUUID", "identityStatus", "taxonKey", "acceptedName",
          "plannedUUID", "role", "note"]
RESOLVED = {"exact", "synonym", "corrected"}


def plan(existing, crosswalk, resolution, worms_status=None):
    """existing: [{id, pack, scientificName}]; crosswalk: {candidateID: row}; resolution: NameResolution rows.
    Returns (rows, report)."""
    by_input = {(r["inputKind"], r["inputID"]): r for r in resolution}
    members = []  # (order, row dict)
    for order, record in enumerate(existing):
        res = by_input.get(("existing", record["id"]), {})
        members.append({"inputKind": "existing", "inputID": record["id"], "pack": record["pack"], "inputName": record["scientificName"],
                        "inputUUID": record["id"], "identityStatus": "app_record", "res": res, "order": order})
    for order, (candidate_id, row) in enumerate(crosswalk.items(), start=len(existing)):
        res = by_input.get(("candidate", candidate_id), {})
        members.append({"inputKind": "candidate", "inputID": candidate_id, "pack": "", "inputName": row["sourceName"],
                        "inputUUID": row["speciesID"], "identityStatus": row["identityStatus"], "res": res, "order": order})

    taxa, unresolved = {}, []
    for m in members:
        res = m["res"]
        if res.get("resolution") in RESOLVED:
            m["taxonKey"], m["acceptedName"] = f"{res['server']}:{res['specCode']}", res["acceptedName"]
            taxa.setdefault(m["taxonKey"], []).append(m)
        else:
            m["taxonKey"], m["acceptedName"] = "", ""
            unresolved.append(m)

    conflicts, collisions, owner_of_uuid = [], [], {}
    for key, group in sorted(taxa.items()):
        app = sorted({m["inputUUID"] for m in group if m["inputKind"] == "existing"})
        workbook = sorted({m["inputUUID"] for m in group if m["identityStatus"] == "existing_identity"})
        names = sorted({m["inputName"] for m in group})
        if len(app) > 1:
            conflicts.append({"kind": "several existing app records for one taxon", "taxonKey": key, "acceptedName": group[0]["acceptedName"], "uuids": app, "names": names})
            chosen = None
        elif app:
            chosen = app[0]
        elif len(workbook) > 1:
            conflicts.append({"kind": "several workbook identities for one taxon", "taxonKey": key, "acceptedName": group[0]["acceptedName"], "uuids": workbook, "names": names})
            chosen = None
        elif workbook:
            chosen = workbook[0]
        else:
            chosen = min(group, key=lambda m: m["order"])["inputUUID"]
        if len({m["inputUUID"] for m in group}) > 1:
            collisions.append({"taxonKey": key, "acceptedName": group[0]["acceptedName"], "keptUUID": chosen,
                               "members": [f"{m['inputKind']}:{m['inputID']} ({m['inputName']})" for m in sorted(group, key=lambda m: m["order"])]})
        for m in group:
            m["plannedUUID"] = chosen or ""
            m["role"] = "conflict" if chosen is None else ("keep" if m["inputUUID"] == chosen else "retire")
            owner_of_uuid.setdefault(m["inputUUID"], set()).add(key)
    for uuid_value, keys in sorted(owner_of_uuid.items()):
        if len(keys) > 1:
            conflicts.append({"kind": "one UUID claimed by several taxa", "uuids": [uuid_value], "taxonKeys": sorted(keys)})
    for m in unresolved:
        m["plannedUUID"], m["role"] = "", "unresolved"
        m["note"] = m["res"].get("resolution") or "no resolution"

    rows = [{f: m.get(f, "") for f in FIELDS} for m in sorted(members, key=lambda m: m["order"])]
    worms = worms_status or {}
    report = {
        "status": "blocked: resolve conflicts before merging" if conflicts else "ready",
        "inputs": {"existingAppRecords": len(existing), "candidates": len(crosswalk)},
        "taxonAuthority": "FishBase/SeaLifeBase v26.06 (NameResolution.csv)",
        "wormsConfirmedCandidates": sum(1 for s in worms.values() if s == "confirmed"),
        "wormsTaxonomyStatus": dict(sorted({s: sum(1 for v in worms.values() if v == s) for s in set(worms.values())}.items())),
        "acceptedTaxa": len(taxa),
        "unresolvedInputs": {"existing": sum(m["inputKind"] == "existing" for m in unresolved), "candidates": sum(m["inputKind"] == "candidate" for m in unresolved)},
        "retiredUUIDs": sum(r["role"] == "retire" for r in rows),
        "collisions": len(collisions), "conflicts": conflicts, "collisionDetails": collisions,
    }
    return rows, report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=REPO / "Data/GlobalMarine/FishBase")
    args = parser.parse_args(argv)
    output = Path(args.output)
    existing = []
    for pack in ("Caribbean", "TropicalPacific"):
        existing += [{"id": r["id"], "pack": pack, "scientificName": r["scientificName"]}
                     for r in json.loads((REPO / "DiveID/Resources/IdentificationPacks" / pack / "Creatures.json").read_text())]
    with open(REPO / "Data/GlobalMarine/IntakeCrosswalk.csv", newline="") as f:
        crosswalk = {r["candidateID"]: r for r in csv.DictReader(f) if r["queue"] == "primary"}
    with open(REPO / "Data/GlobalMarine/OriginalNameCrosswalk.csv", newline="") as f:
        worms = {r["candidateID"]: r["taxonomyStatus"] for r in csv.DictReader(f) if r["queue"] == "primary"}
    with open(output / "NameResolution.csv", newline="") as f:
        resolution = list(csv.DictReader(f))
    rows, report = plan(existing, crosswalk, resolution, worms)
    with open(output / "MergePlan.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    (output / "MergePlanReport.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k != "collisionDetails"}, indent=2, ensure_ascii=False))
    return 2 if report["conflicts"] else 0


if __name__ == "__main__":
    sys.exit(main())
