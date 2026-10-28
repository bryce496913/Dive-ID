# TestFlight: a Release build for a few dive friends

Prepared 2026-10-28. **Nothing here has been uploaded or sent.** Bryce does the
upload and the invitations.

## What's already set

- **Version 0.5, build 3** (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). Every
  upload needs a higher build number; raise it before each new archive.
- **Bundle ID** `com.brycecameron.DiveID`, team `7ZAXQ2686Z`, automatic signing.
- **Archive configuration is Release.** The shared `DiveID` scheme's Archive action uses
  Release, which defines neither `DEBUG` nor `DIVEID_INTERNAL`. The diagnostics strip,
  the internal banner and the draft catalogue are compiled out, and Release offers only
  approved records.
- **Export compliance:** `ITSAppUsesNonExemptEncryption = NO` in `Info.plist`. Dive ID
  makes no network connections and uses no encryption; its only cryptographic code is a
  SHA-256 content hash. App Store Connect then won't ask about encryption per build.
- **Privacy manifest** (`DiveID/PrivacyInfo.xcprivacy`):
  - no tracking and no tracking domains;
  - required-reason APIs: `UserDefaults` (CA92.1, the app's own settings) and file
    timestamps (C617.1, files in the app's own container);
  - collected data: the diver's descriptions and optional details ("Other User
    Content"), plus the random participant code ("User ID"). Both are sent only when
    the diver chooses **Share my feedback**, for analytics (testing identification
    quality), linked to whoever sends the file, and never used for tracking.

  Answer the App Store Connect **App Privacy** questions the same way; they're not
  filled from the manifest automatically.

## Archive and upload (Xcode Organizer)

1. Open `Dive ID/Dive-ID/DiveID.xcodeproj`. Check the path: the old `Dive-ID-main`
   copy is out of date.
2. In the toolbar, choose the **DiveID** scheme and **Any iOS Device (arm64)**.
3. **Product → Archive.** When it finishes, the Organizer opens on the new archive
   (version 0.5, build 3).
4. **Distribute App → TestFlight & App Store → Distribute.** Keep automatic signing
   and "Upload your app's symbols".
5. Wait for "processing" to finish in App Store Connect (TestFlight tab), usually
   15–30 minutes. You'll get an email.

If App Store Connect has no Dive ID app yet: **Apps → + → New App**, iOS, name
"Dive ID", bundle ID `com.brycecameron.DiveID`, any unique SKU. Then upload as above.

## Testers

- **Internal testers** (people in your App Store Connect team, up to 100): add them
  under **TestFlight → Internal Testing**. No review needed.
- **External testers** (your dive friends, outside your team): **Beta App Review is
  required** before the first external build can be tested. Later builds of the same
  version usually go through faster.
  1. **TestFlight → External Testing → +** to create a group, e.g. "Dive friends".
  2. Add the build to the group, fill in **Test Information** (feedback email,
     description, beta app review contact; no sign-in needed) and the **What to Test**
     notes below, then **Submit for Review**.
  3. After approval, add testers by email, or turn on a **public link** and send that.
     Testers install the free TestFlight app and accept the invitation.

## What to Test (paste into App Store Connect)

> Thanks for trying Dive ID! It identifies marine life from a description, entirely
> on your phone.
>
> **Before you look anything up**, think of one animal you saw on a dive and describe
> it in your own words on **Describe What You Saw**: colours, shape, size, markings,
> what it was doing, where. Please don't check a guide or the app's species list first.
> Your first search is the most useful one.
>
> Then tell us **"Was this right?"** below the results. "None of these" and "Not sure"
> are just as helpful as "Yes".
>
> Afterwards, go to **Home → Data Sources and Credits → Share my feedback** to send your
> answers to Bryce (you'll see exactly what's included first). Nothing is sent unless
> you do that, and you choose whether your words may be used for testing or quoted.
>
> Also useful: anything confusing, slow or broken. Use TestFlight's screenshot feedback.

## Invitation message (for you to send)

> Hi! I'm building **Dive ID**, an iPhone app that identifies fish and other marine
> life from a description, completely offline. Would you try a test version?
>
> It takes five minutes: install TestFlight, open my link, then describe one animal you
> remember from a dive **in your own words, before looking anything up**, and say
> whether the app got it right. At the end you can send me your answers from inside the
> app; nothing is sent unless you choose to, and you decide whether I may use or quote
> your wording.
>
> Here's the link: [TestFlight public link]
>
> Thanks! A photo of the animal, if you have one, helps me check the answer.

## Pilot bookkeeping

Shared files go to the custodian, never into Git. Import them with
`Tools/Evaluation/import_feedback.py` (see `Data/Evaluation/IndependentDiverCollection.md`),
then update the counter in the README.
