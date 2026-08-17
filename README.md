# ContactCleaner — Read-only Build 1

Native iOS SwiftUI Contacts analyzer for a private device-install workflow.

## Safety state

This build performs **no writes** to Contacts. It contains no `CNSaveRequest`, no contact creation, no contact update, and no contact deletion.

## Run on iPhone

1. Open `ContactCleaner.xcodeproj` in Xcode.
2. Select the `ContactCleaner` target.
3. Signing & Capabilities → select your Apple Development Team.
4. If the bundle identifier conflicts, change `com.cihatoz.ContactCleaner` to a unique value.
5. Connect the iPhone and select it as the run destination.
6. Run.
7. When iOS asks for Contacts access, choose access to **all contacts**.
8. Tap **Rehberi Tara**.

## Current scope

- Source/container discovery
- Raw contact scan (`unifyResults = false`)
- Unified contact count (`unifyResults = true`)
- Turkish phone normalization
- Turkish-character-aware name normalization
- Email normalization
- Exact + controlled fuzzy duplicate candidate generation
- Definite / High / Review classification
- Same-name / different-number records intentionally appear in Review
- Source counts and health dashboard
- Duplicate detail with matching evidence

## Intentionally deferred

- Backup / vCard export
- Notes entitlement
- Merge preview
- `CNSaveRequest`
- Delete / consolidation
- Undo / operation journal
