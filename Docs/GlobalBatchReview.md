# Global pack batch review

The 4,786 Global records are approved in batches of about 250. For each batch, the
reviewer reads every flagged record and a seeded random sample of 30 unflagged records.
The tool is `Tools/CatalogReview/global_batches.py`.

## Steps

1. **Prepare a batch.** Run `python3 Tools/CatalogReview/global_batches.py prepare --batch N`. It writes:
   - `Data/CatalogReview/GlobalBatches/batch-NN/manifest-gG-<hash>.json`, which lists every
     speciesID with:
     - its `reviewedContentFingerprint`;
     - whether it is `flagged`, `sampled` or `unread`;
     - the seed and the manifest's own SHA-256.
   - `Reports/GlobalReview/batch-NN-gG-<hash>.html`. It shows the flagged records
     (highest risk first, with their flags), then the sample. Every published field and
     every source link is shown.

   A fresh seed is drawn and recorded unless `--seed` is given. The same seed always
   gives the same sample and the same manifest.
2. **Review and decide.** The reviewer reads the page and states a decision for that
   manifest hash.
3. **Record the decision.** The recording tool runs only with the reviewer's own words
   from the review session:

   ```sh
   python3 Tools/CatalogReview/global_batches.py record --manifest-sha256 <hash> \
     --reviewer Bryce --decision-text "<verbatim decision>" --outcome approve|reject \
     [--exclude ID=note] [--reject ID=note] [--reason "..."] [--date YYYY-MM-DD]
   ```

   It writes `batch-NN/<Reviewer>Review<date>-batch-NN-gG.json` in the
   `Data/CatalogReview/BryceReview2026-10-12.json` schema, with these additions:
   - `batchManifestSHA256`, `seed` and `generation`;
   - a `reviewMethod` on each approved record;
   - `heldRecords`, for excluded, rejected or stale records;
   - `rejection`, for a rejected batch.
4. **Apply.** Run `python3 Tools/FishBaseIntake/publish_global.py`. It marks the
   approved records verified in the Global pack and updates the manifest counts.

## Rules

- **Review method.**
  - Flagged and sampled records are `individually-reviewed`.
  - Unread records are `sample-approved`.
  - The species screen says "individually reviewed" only for the first.
- **Excluded or rejected records stay drafts.** Each one is recorded with its note.
- **A sampled error rejects the batch.** Rejecting any sampled record rejects the
  whole batch, and no record in it is approved. After fixes, run `prepare` again.
  It refuses a seed already used for that batch, and a new generation replaces the
  old one.
- **One decision per manifest.** Recording is refused for:
  - a manifest that already has a decision;
  - a superseded manifest;
  - a tampered manifest, whose content no longer matches its own SHA-256.
- **Fail closed.**
  - Only the newest manifest of a batch counts.
  - A record is approved only while its current content matches the fingerprint in
    that manifest. A change before recording leaves it `stale` in the overlay; a
    change after recording drops its approval when the pack is rebuilt.
  - Review fields such as status and notes are not part of the fingerprint.
- **Overlays are never written by hand or by an assistant.** No earlier statement,
  including `Data/GlobalMarine/CandidateApprovalContext.json`, counts as a decision.
- **Release visibility.** Release builds show only verified records. **Approving the
  first batch therefore makes the Global pack visible in Release,** showing that
  batch's approved records. `GlobalPackTests` currently asserts that Global is
  Debug-only and will fail at that point, deliberately, until the change is accepted.

## Status

| Batch | Generation | Manifest SHA-256 | Seed | Flagged | Sampled | Unread | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- |
| batch-01 | 1 | `35450343a04f7062a1921ed1b8cffa1df4e9e82e30ac21d608f066bb922d9691` | 249769802202299688 | 4 | 30 | 216 | awaiting review |
