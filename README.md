# Rehberss — iOS Contact Cleaner

Native Swift + SwiftUI contact cleanup tool for direct Xcode installation on a personal iPhone.

## Goal

Scan a large iPhone address book across iCloud, Gmail, Exchange, CardDAV and local containers, find duplicate people safely, merge their information without silently dropping accessible fields, and consolidate unique records into a preferred iCloud address book.

## Current scope

- Full Contacts permission handling (iOS 18+)
- Raw contact scan with `unifyResults = false`
- Separate unified contact count with `unifyResults = true`
- Source/container discovery (iCloud, Gmail, Exchange, CardDAV, local)
- Turkish phone normalization (`05xx`, `5xx`, `+905xx`, `0090...`)
- Turkish-character-aware name normalization
- E-mail normalization
- Exact + controlled fuzzy duplicate matching
- Definite / High / Review confidence levels
- Same-name / different-number records intentionally land in **Review**, never automatic merge
- Transitive-cluster safety checks
- Contact health dashboard
- Before/after merge preview
- Full local JSON snapshot backup + vCard backup
- Accessible-field preservation: names, phones, e-mails, company/title/department, postal addresses, URLs, relations, dates, social profiles, IM addresses, birthdays, photo and Notes when entitlement is available
- Group/list name migration where the target provider supports groups
- Master record written to iCloud, re-fetched and verified **before** source records are deleted
- Safe bulk merge for conflict-free definite duplicates only
- Unique Gmail/Exchange/CardDAV/local → iCloud migration
- Operation journal + Undo
- macOS GitHub Actions iOS compile check

## Safety rules

1. No destructive action runs without an explicit user action.
2. A backup is created before merge/migration workflows.
3. The destination record is saved and re-read from `CNContactStore`.
4. Phones, e-mails, postal addresses, URLs, relations, photo presence and Notes (when accessible) are verified before source deletion.
5. Risky/high/review matches are never included in bulk cleanup.
6. Same name alone is not enough for automatic merge.
7. If a record is part of an unresolved duplicate cluster, iCloud bulk consolidation skips it.
8. Every completed merge/migration gets an Undo journal record.

## Contacts Notes entitlement

Apple gates `CNContact.note` behind `com.apple.developer.contacts.notes`. The app probes access at runtime.

- With Notes access: Notes are read, merged and verified.
- Without Notes access: destructive operations remain disabled by default.
- Because this is a private personal-use build, the UI contains an explicit advanced override. Enabling it means accepting that Notes cannot be verified/preserved by the app.

Do **not** add the Notes entitlement to Signing & Capabilities unless the Apple Developer account is approved for it; an unapproved entitlement can break signing.

## Run on iPhone

1. Clone/download this repository.
2. Open `ContactCleaner.xcodeproj` in Xcode.
3. Select the `ContactCleaner` target.
4. Signing & Capabilities → choose your Apple Development Team.
5. If necessary, change `com.cihatoz.ContactCleaner` to a unique bundle identifier.
6. Connect the iPhone and select it as the run destination.
7. Run.
8. Grant access to **all contacts**.
9. Tap **Rehberi Tara**.
10. Before destructive cleanup, create a full backup from the **Güvenlik** section.

## Recommended real-address-book sequence

1. Scan only and inspect counts.
2. Open several Definite / High / Review clusters and confirm matcher quality.
3. Merge one known duplicate and verify it in Apple Contacts.
4. Use Undo and verify restoration.
5. Merge a few known duplicates manually.
6. Use **Güvenli Kesin Duplicate'leri Birleştir**.
7. Review remaining High / Review clusters manually.
8. Use **Benzersiz Kayıtları iCloud'a Taşı** for records outside unresolved duplicate clusters.
9. Re-scan and verify final source counts.
10. Only after verification, disable Gmail/Exchange contact sync from iOS Settings if desired.

## Architecture note

The app treats an Apple `CNContact` record as a source record, not as the future product's permanent person identity. The domain layer is intentionally ready for a later `Person` identity layer so Smart Contacts / Call Memory features can be added without binding timeline data to unstable Contacts identifiers.
