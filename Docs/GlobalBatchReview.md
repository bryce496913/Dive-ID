# Global pack batch review

The 4,798 Global records (4,786 built from FishBase and SeaLifeBase, the 8 carried
Caribbean records and 4 owner additions) are approved in batches of about 250. For each batch, the reviewer
reads every flagged record and a seeded random sample of 30 unflagged records.
The tool is `Tools/CatalogReview/global_batches.py`.

Numbered batches partition the pack: each FishBase record is in its build batch
(`batch` in `Data/GlobalMarine/FishBase/RiskReport.json`), and records absent from the
risk report, the 8 carried Caribbean records, join the last build batch (batch-20).
Owner additions are in numbered batches of their own after the build batches (batch-21). Their risk
flags come from the current record validators (`catalogue_validation.risk_flags`).

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
     [--exclude ID=note] [--reject ID=note] [--reason "..."] [--date YYYY-MM-DD] \
     [--all-individually-reviewed]
   ```

   `--all-individually-reviewed` is only for a reviewer who states they read every record
   in the batch, not only those on the page; it marks every approved record
   individually-reviewed and records that basis in the overlay.

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
  - a superseded manifest: an older generation of its batch, or a re-review batch
    whose original batch has a newer generation (that generation covers the records again);
  - a tampered manifest, whose content no longer matches its own SHA-256.
- **Fail closed.**
  - Only the newest manifest of a batch counts.
  - A record is approved only while its current content matches the fingerprint in
    that manifest. A change before recording leaves it `stale` in the overlay; a
    change after recording drops its approval when the pack is rebuilt.
  - Review fields such as status and notes are not part of the fingerprint.
- **Overlays are never written by hand or by an assistant.** No earlier statement,
  including `Data/GlobalMarine/CandidateApprovalContext.json`, counts as a decision.
- **Release visibility.** Release builds show only verified records, and only from packs
  whose definition is `availableInRelease`. Bryce opened Global's gate
  (`GlobalRegion.swift`) on 2026-10-23, with his approval of all 20 current batches.
  `GlobalPackTests` asserts that Release exposes exactly the records the recorded
  approvals cover, and that a closed gate still keeps a pack out of Release even when
  some of its records are approved. Closing it again is a one-line change to
  `GlobalRegion.definition`.
- **Pack version.** The Global `packVersion` rises with each recorded approval and
  never falls when a new generation supersedes an approved one.

## Re-review after a rebuild

A rebuild that changes an approved record's content changes its fingerprint, so its
approval lapses. `prepare --batch N --rereview` writes a separate batch,
`batch-NN-rereview`, holding only those records, with the same flagged-plus-sample
rule. batch-NN itself is left alone, so its unchanged records keep their approval.
`publish_global.py` writes the approvals it actually applied, and the approved
records that went stale, to `Data/CatalogReview/GlobalBatches/AppliedApprovals.json`.

## Current-content review (2026-10-23)

All earlier approvals are stale: the content changed after batch 1 was approved. These
20 batches cover the current pack, all 4,794 records, each exactly once, against its
current fingerprints. The FishBase risk flags were checked by rebuilding the drafts from the
pinned v26.06 tables with the current builder and validators: `RiskReport.json`, the
drafts and `ClueTrace.json` came out byte-identical, so `trait_ambiguous` (including
`trait_ambiguous:negation_scope`) and the negation rules are current. batch-01
generation 2 supersedes batch-01 generation 1 and both batch-01-rereview generations;
none of those can be recorded against.

To read: **1,363 flagged** and **600 sampled** records, 1,963 in all. The other
2,831 are sample-approved if their batch is approved.

**Decision (2026-10-23).** Bryce approved all 20 batches with the decision text
"I have reviewed all of the entries and have approved them. All creatures can move into
approved." It was recorded once per current manifest with
`global_batches.py record --outcome approve --date 2026-10-23`: 4,794 records approved,
none held, every fingerprint matching the manifest, and the gate was opened (see "Release
visibility"). Those overlays first used the default methods (1,963 individually reviewed,
2,831 sample-approved). At Bryce's direction ("re-recorded as individually-reviewed for
all 4,794 as you originally wrote"), they were replaced the same day by overlays recorded
with `--all-individually-reviewed`, which marks every approved record individually-reviewed
and stores `reviewMethodBasis`: it rests on his statement that he reviewed every entry, not
on the review pages, which showed the 2,831 unread records by name only. This is the one
time recorded overlays were replaced; the earlier ones are in git history (PR #138).

Take them in this order: highest flagged count first, ties by batch number.

| Order | Batch | Generation | Records | Flagged | Sampled | Manifest SHA-256 | Review page |
| --- | --- | --- | ---: | ---: | ---: | --- | --- |
| 1 | batch-01 | 2 | 250 | 87 | 30 | `9cddefd45f1b4e11fbcbfcb16c543b2ad362669c9c3324511d9b228cd607c896` | [batch-01-g2-9cddefd45f1b.html](../Reports/GlobalReview/batch-01-g2-9cddefd45f1b.html) |
| 2 | batch-12 | 1 | 250 | 87 | 30 | `ea8e353b1bcf3550a9f841f99fd184f222068764823fd9d48a1640ebf29ab8ea` | [batch-12-g1-ea8e353b1bcf.html](../Reports/GlobalReview/batch-12-g1-ea8e353b1bcf.html) |
| 3 | batch-04 | 1 | 250 | 85 | 30 | `46c41406bc4cde15feada9182fdf936901525412ddfeb7b3d3a43d6c6c5b9bd2` | [batch-04-g1-46c41406bc4c.html](../Reports/GlobalReview/batch-04-g1-46c41406bc4c.html) |
| 4 | batch-13 | 1 | 250 | 84 | 30 | `f6b78a61650a20c7838388cb85e5351c7850e71405d52ea824d46955b0f64b89` | [batch-13-g1-f6b78a61650a.html](../Reports/GlobalReview/batch-13-g1-f6b78a61650a.html) |
| 5 | batch-14 | 1 | 250 | 83 | 30 | `f5bebe673310daaf692863ea235c924721ec523a55134ea03e912a024f0ec652` | [batch-14-g1-f5bebe673310.html](../Reports/GlobalReview/batch-14-g1-f5bebe673310.html) |
| 6 | batch-03 | 1 | 250 | 81 | 30 | `cc50751f1853d81a40776470bc50e480ded0f771b384448fef0feb03ee35d826` | [batch-03-g1-cc50751f1853.html](../Reports/GlobalReview/batch-03-g1-cc50751f1853.html) |
| 7 | batch-05 | 1 | 250 | 81 | 30 | `f3f45fa95e346392fbf21659ddb098a3649809dd83c58a6e1234b97ae8d921eb` | [batch-05-g1-f3f45fa95e34.html](../Reports/GlobalReview/batch-05-g1-f3f45fa95e34.html) |
| 8 | batch-02 | 1 | 250 | 80 | 30 | `686abe319fbc46410a1f1f3abe31c598a49eb4f9ff852ca727b92fdabc5e7bc0` | [batch-02-g1-686abe319fbc.html](../Reports/GlobalReview/batch-02-g1-686abe319fbc.html) |
| 9 | batch-10 | 1 | 250 | 80 | 30 | `c945eb857869f22eeb3f3a6019f819190ba7ee5b257113d44aa270ff1eab0400` | [batch-10-g1-c945eb857869.html](../Reports/GlobalReview/batch-10-g1-c945eb857869.html) |
| 10 | batch-15 | 1 | 250 | 72 | 30 | `167e83f00b21ee9cb98ca8f3187935028e1425be6e3ff360e3828c7e811f1c93` | [batch-15-g1-167e83f00b21.html](../Reports/GlobalReview/batch-15-g1-167e83f00b21.html) |
| 11 | batch-07 | 1 | 250 | 70 | 30 | `c0c6b7a22d7f9201d0818cc6cf06ecdd2a033c23e83d22886f7dab0d19cd03e2` | [batch-07-g1-c0c6b7a22d7f.html](../Reports/GlobalReview/batch-07-g1-c0c6b7a22d7f.html) |
| 12 | batch-17 | 1 | 250 | 70 | 30 | `b41307dc71d1108c9ce7325612416a1bfa2d006ceec21ec1700c97be08a80f15` | [batch-17-g1-b41307dc71d1.html](../Reports/GlobalReview/batch-17-g1-b41307dc71d1.html) |
| 13 | batch-06 | 1 | 250 | 67 | 30 | `70d7e57a7ba60935ac66a1cc2a724e234f777a9c648de0bcfb4539ad2371a2ee` | [batch-06-g1-70d7e57a7ba6.html](../Reports/GlobalReview/batch-06-g1-70d7e57a7ba6.html) |
| 14 | batch-08 | 1 | 250 | 67 | 30 | `d554e72a4c3332df2ff198f7c5550a95a444ed2e458b0ba009a46c2a39c38b58` | [batch-08-g1-d554e72a4c33.html](../Reports/GlobalReview/batch-08-g1-d554e72a4c33.html) |
| 15 | batch-09 | 1 | 250 | 65 | 30 | `d1b2b6ac9756d65739254ac79887ca4d84257ae002327b4be63d0cb69a949e23` | [batch-09-g1-d1b2b6ac9756.html](../Reports/GlobalReview/batch-09-g1-d1b2b6ac9756.html) |
| 16 | batch-18 | 1 | 250 | 62 | 30 | `d498b98cf5e3feff055bc5c684e8a5e4ea5167784c7abe02377f8b4e772c72ac` | [batch-18-g1-d498b98cf5e3.html](../Reports/GlobalReview/batch-18-g1-d498b98cf5e3.html) |
| 17 | batch-16 | 1 | 250 | 60 | 30 | `632618ec9a954f5dc9c620d0c3480f540db20f84a835eb3f451820723a45237c` | [batch-16-g1-632618ec9a95.html](../Reports/GlobalReview/batch-16-g1-632618ec9a95.html) |
| 18 | batch-11 | 1 | 250 | 56 | 30 | `b593f548d0501f6e9336d89879e3f00248c4056bc6dbdef81922636022990929` | [batch-11-g1-b593f548d050.html](../Reports/GlobalReview/batch-11-g1-b593f548d050.html) |
| 19 | batch-19 | 1 | 249 | 26 | 30 | `01df05baeb2b7f698a280312b2e069ed726f91b5626804d626b4308adc351aa3` | [batch-19-g1-01df05baeb2b.html](../Reports/GlobalReview/batch-19-g1-01df05baeb2b.html) |
| 20 | batch-20 | 1 | 45 | 0 | 30 | `75e0b56d43a324ddea4019789efede24048eae1cd7d8a0b15e23bdccfd7d116f` | [batch-20-g1-75e0b56d43a3.html](../Reports/GlobalReview/batch-20-g1-75e0b56d43a3.html) |

batch-19 has 249 records because one FishBase record of its build batch is left out of
the pack (missing geographic range). batch-20 holds the last 37 FishBase records and the
8 carried Caribbean records. Its seeded sample shows 4 of the 8
(Stoplight Parrotfish, Red Lionfish, Great Barracuda, Queen Angelfish); the other 4
(Atlantic Blue Tang, Green Sea Turtle, Spotted Eagle Ray, French Angelfish) would be
sample-approved. To read those as well, exclude them when recording, so they stay drafts
for a later named batch.

Record one decision per manifest, with your own words for that hash:

```sh
python3 Tools/CatalogReview/global_batches.py record --manifest-sha256 <manifest SHA-256> \
  --reviewer Bryce --decision-text "<your verbatim decision>" --outcome <approve|reject> \
  [--exclude <speciesID>=<note>] [--reject <speciesID>=<note>] [--reason "<why rejected>"] [--date <YYYY-MM-DD>]
python3 Tools/FishBaseIntake/publish_global.py
```

A rejected sampled record rejects the whole batch. After fixes, run
`prepare --batch N` again for a new generation with a new seed.

## Owner additions (2026-10-23)

Bryce asked for Whitetip reef shark, Grey reef shark, Zebra shark and Reef manta. They
were added through `Data/GlobalMarine/OwnerAdditions.csv` (see
`Tools/FishBaseIntake/README.md`) as **batch-21**, a batch of their own after the 20
build batches, so no approved batch's records moved. Caribbean reef shark was already in
Global. Bryce approved batch-21 on 2026-10-23 ("4 new species (whitetip reef, grey reef,
zebra shark, reef manta) move them over as approved"); all four are individually reviewed
and in Release.

| Species | Scientific name | Flags |
| --- | --- | --- |
| Whitetip reef shark | *Triaenodon obesus* | `trait_ambiguous:colors/markings` |
| Grey reef shark | *Carcharhinus amblyrhynchos* | `trait_ambiguous:colors` |
| Zebra shark | *Stegostoma tigrinum* | `trait_ambiguous:colors/markings` |
| Reef manta ray | *Mobula alfredi* | none (sampled) |

"Grey reef shark" uses Bryce's name; FishBase's main name, "Blacktail reef shark", is an
alias, and so is "Gray reef shark". Those names were aliases of Graceful shark ("Grey reef
shark") and Silky shark ("Gray reef shark"), so a search for the species found the wrong
ones. The aliases now belong to the new record alone. Removing them changed those two
records, so their batch-18 approval lapsed and they were drafts, out of Release, until
**batch-18-rereview** was decided. The other 248 batch-18 records keep their approval.

Bryce approved batch-18-rereview on 2026-10-26: "I reviewed Graceful shark and Silky shark
in batch-18-rereview, including the removal of the wrong Grey/Gray reef shark aliases, and
I approve both." Both are individually reviewed and in Release, so every one of Global's
4,798 records is approved (pack version 25) and none awaits review. "Grey reef shark" and
"Gray reef shark" still find Grey reef shark first. To record a later decision and
republish:

```sh
python3 Tools/CatalogReview/global_batches.py record --manifest-sha256 <hash> \
  --reviewer Bryce --decision-text "<verbatim decision>" --outcome approve|reject
python3 Tools/FishBaseIntake/publish_global.py
```

## Status

| Batch | Generation | Manifest SHA-256 | Seed | Flagged | Sampled | Unread | Decision |
| --- | --- | --- | --- | --- | --- | --- | --- |
| batch-01 | 1 | `35450343a04f7062a1921ed1b8cffa1df4e9e82e30ac21d608f066bb922d9691` | 249769802202299688 | 4 | 30 | 216 | approved 2026-10-22 by Bryce ("I have. approved all"). All 250 approvals lapsed when the builder v3 rebuild changed the records. Superseded by generation 2 (2026-10-23). |
| batch-01-rereview | 1 | `d1e7e47d4724cd05f630bf162942734ba2271330bad79b220a15575d7bacfcfd` | 2799262242171053537 | 86 | 30 | 134 | superseded by generation 2, undecided. All 250 batch-01 records changed in the builder v3 rebuild (2026-10-22): 221 in identification content and 29 only in the new `dataSources.sourceFields` provenance list. None keeps its approval. |
| batch-01 | 2 | `9cddefd45f1b4e11fbcbfcb16c543b2ad362669c9c3324511d9b228cd607c896` | 6620643215757994745 | 87 | 30 | 133 | approved 2026-10-23 by Bryce (decision text above). |
| batch-02 | 1 | `686abe319fbc46410a1f1f3abe31c598a49eb4f9ff852ca727b92fdabc5e7bc0` | 9064425676869974389 | 80 | 30 | 140 | approved 2026-10-23 by Bryce (decision text above). |
| batch-03 | 1 | `cc50751f1853d81a40776470bc50e480ded0f771b384448fef0feb03ee35d826` | 1150192674019228709 | 81 | 30 | 139 | approved 2026-10-23 by Bryce (decision text above). |
| batch-04 | 1 | `46c41406bc4cde15feada9182fdf936901525412ddfeb7b3d3a43d6c6c5b9bd2` | 4583211733273006097 | 85 | 30 | 135 | approved 2026-10-23 by Bryce (decision text above). |
| batch-05 | 1 | `f3f45fa95e346392fbf21659ddb098a3649809dd83c58a6e1234b97ae8d921eb` | 6170256753491440946 | 81 | 30 | 139 | approved 2026-10-23 by Bryce (decision text above). |
| batch-06 | 1 | `70d7e57a7ba60935ac66a1cc2a724e234f777a9c648de0bcfb4539ad2371a2ee` | 5709548382389902958 | 67 | 30 | 153 | approved 2026-10-23 by Bryce (decision text above). |
| batch-07 | 1 | `c0c6b7a22d7f9201d0818cc6cf06ecdd2a033c23e83d22886f7dab0d19cd03e2` | 8906990601601499119 | 70 | 30 | 150 | approved 2026-10-23 by Bryce (decision text above). |
| batch-08 | 1 | `d554e72a4c3332df2ff198f7c5550a95a444ed2e458b0ba009a46c2a39c38b58` | 5180136277957005184 | 67 | 30 | 153 | approved 2026-10-23 by Bryce (decision text above). |
| batch-09 | 1 | `d1b2b6ac9756d65739254ac79887ca4d84257ae002327b4be63d0cb69a949e23` | 3983373252997082561 | 65 | 30 | 155 | approved 2026-10-23 by Bryce (decision text above). |
| batch-10 | 1 | `c945eb857869f22eeb3f3a6019f819190ba7ee5b257113d44aa270ff1eab0400` | 1417251802194022862 | 80 | 30 | 140 | approved 2026-10-23 by Bryce (decision text above). |
| batch-11 | 1 | `b593f548d0501f6e9336d89879e3f00248c4056bc6dbdef81922636022990929` | 8119467024620482905 | 56 | 30 | 164 | approved 2026-10-23 by Bryce (decision text above). |
| batch-12 | 1 | `ea8e353b1bcf3550a9f841f99fd184f222068764823fd9d48a1640ebf29ab8ea` | 961158327718651566 | 87 | 30 | 133 | approved 2026-10-23 by Bryce (decision text above). |
| batch-13 | 1 | `f6b78a61650a20c7838388cb85e5351c7850e71405d52ea824d46955b0f64b89` | 9165081101871360616 | 84 | 30 | 136 | approved 2026-10-23 by Bryce (decision text above). |
| batch-14 | 1 | `f5bebe673310daaf692863ea235c924721ec523a55134ea03e912a024f0ec652` | 5452742877917365280 | 83 | 30 | 137 | approved 2026-10-23 by Bryce (decision text above). |
| batch-15 | 1 | `167e83f00b21ee9cb98ca8f3187935028e1425be6e3ff360e3828c7e811f1c93` | 5962894279841414666 | 72 | 30 | 148 | approved 2026-10-23 by Bryce (decision text above). |
| batch-16 | 1 | `632618ec9a954f5dc9c620d0c3480f540db20f84a835eb3f451820723a45237c` | 3170227035746323471 | 60 | 30 | 160 | approved 2026-10-23 by Bryce (decision text above). |
| batch-17 | 1 | `b41307dc71d1108c9ce7325612416a1bfa2d006ceec21ec1700c97be08a80f15` | 5929038167441915047 | 70 | 30 | 150 | approved 2026-10-23 by Bryce (decision text above). |
| batch-18 | 1 | `d498b98cf5e3feff055bc5c684e8a5e4ea5167784c7abe02377f8b4e772c72ac` | 6448878743500968022 | 62 | 30 | 158 | approved 2026-10-23 by Bryce (decision text above). |
| batch-19 | 1 | `01df05baeb2b7f698a280312b2e069ed726f91b5626804d626b4308adc351aa3` | 5304005859740104966 | 26 | 30 | 193 | approved 2026-10-23 by Bryce (decision text above). |
| batch-20 | 1 | `75e0b56d43a324ddea4019789efede24048eae1cd7d8a0b15e23bdccfd7d116f` | 2200883920732990615 | 0 | 30 | 15 | approved 2026-10-23 by Bryce (decision text above). |
| batch-01-rereview | 2 | `a855aeef9fda952f23a33a4744b447e067a37ac7b6491100e1b2c9e2bfd909ce` | 5457129314686080825 | 87 | 30 | 133 | superseded by batch-01 generation 2 (2026-10-23), undecided. Prepared after the builder v4 negation repair (2026-10-22) changed 22 of the generation 1 records. |
| batch-21 | 1 | `b55810bae4d98f4ba20f7663e8700aab54f55d3dc33521aad854441c99670890` | 5609686461008101448 | 3 | 1 | 0 | **approved** 2026-10-23 by Bryce: "4 new species (whitetip reef, grey reef, zebra shark, reef manta) move them over as approved". 4 approved, all individually reviewed, none held. Overlay `batch-21/BryceReview2026-10-23-batch-21-g1.json`. |
| batch-18-rereview | 1 | `a02ce879eca116d81fb3645f378f4d3f82aaa74e6bdd00ba912f7a549e2b460c` | 6703939030536056391 | 1 | 1 | 0 | **approved** 2026-10-26 by Bryce: "I reviewed Graceful shark and Silky shark in batch-18-rereview, including the removal of the wrong Grey/Gray reef shark aliases, and I approve both." 2 approved, both individually reviewed, none held. Overlay `batch-18-rereview/BryceReview2026-10-26-batch-18-rereview-g1.json`. |

