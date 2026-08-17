# Rehberss — Contact cleanup safety model

The app is local-first and designed for direct Xcode installation on a personal iPhone.

## Destructive-operation gates

A contact is never deleted until all of the following are true:

1. A local full-address-book JSON backup exists.
2. The selected cluster has a merge preview.
3. The user explicitly confirms the merge.
4. The destination contact is saved and re-fetched successfully.
5. All accessible multi-value fields from the sources are present in the destination.
6. Only then are redundant source contacts deleted.

Bulk cleanup is limited to conflict-free `definite` clusters. Review/high-probability clusters stay manual.

## Notes

`CNContact.note` requires Apple's `com.apple.developer.contacts.notes` entitlement. The app performs a runtime capability probe. Safe destructive cleanup is blocked while notes access is unavailable unless the device owner explicitly enables the advanced override acknowledging that Notes cannot be verified/preserved.

## Account consolidation

The preferred destination is an iCloud container. A cluster that already has an iCloud record updates that record. Otherwise the app creates a new contact in the selected iCloud container, verifies it, then removes confirmed redundant records from other writable containers.

## Undo

Every merge stores an operation journal with pre-merge snapshots. Undo restores the original destination state and recreates deleted source contacts in their original containers where possible. If the original container no longer exists, the UI reports that the record cannot be restored there rather than silently moving it.
