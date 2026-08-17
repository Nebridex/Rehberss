import Contacts
import Foundation

extension ContactMaintenanceService {
    struct BulkMergeSummary: Sendable {
        let eligibleCount: Int
        let attemptedCount: Int
        let successCount: Int
        let failedCount: Int
        let cancelled: Bool
        let failureMessages: [String]
    }

    func mergePreview(for cluster: PersonCluster, preferredContainerID: String) -> MergePreview {
        let target = cluster.contacts.first(where: { $0.source.id == preferredContainerID }) ?? cluster.contacts.first
        let organizations = nonEmptyUnique(cluster.contacts.map(\.organizationName))
        let departments = nonEmptyUnique(cluster.contacts.map(\.departmentName))
        let titles = nonEmptyUnique(cluster.contacts.map(\.jobTitle))
        let birthdays = uniqueDates(cluster.contacts.compactMap(\.birthday))
        let nonGregorianBirthdays = uniqueDates(cluster.contacts.compactMap(\.nonGregorianBirthday))
        let imageCount = Set(cluster.contacts.compactMap(\.imageData)).count

        var warnings: [String] = []
        if organizations.count > 1 { warnings.append("Şirket bilgileri birleştirilecek: \(organizations.joined(separator: " / "))") }
        if departments.count > 1 { warnings.append("Departman bilgileri birleştirilecek: \(departments.joined(separator: " / "))") }
        if titles.count > 1 { warnings.append("Unvan bilgileri birleştirilecek: \(titles.joined(separator: " / "))") }
        if birthdays.count > 1 { warnings.append("Doğum günü çakışıyor; master kaydın değeri korunacak.") }
        if nonGregorianBirthdays.count > 1 { warnings.append("Alternatif takvim doğum günü çakışıyor; master kaydın değeri korunacak.") }
        if imageCount > 1 { warnings.append("Birden fazla fotoğraf var; master kaydın fotoğrafı, yoksa en büyük fotoğraf korunacak.") }

        return MergePreview(
            clusterID: cluster.id,
            targetContactID: target?.id,
            targetContainerID: preferredContainerID,
            displayName: bestName(cluster.contacts),
            phones: unique(cluster.contacts.flatMap(\.phones)) { PhoneNormalizer.normalize($0.value) },
            emails: unique(cluster.contacts.flatMap(\.emails)) { EmailNormalizer.normalize($0.value) },
            organizationName: organizations.joined(separator: " / "),
            departmentName: departments.joined(separator: " / "),
            jobTitle: titles.joined(separator: " / "),
            selectedBirthday: target?.birthday ?? birthdays.first,
            warnings: warnings,
            requiresExplicitConflictConfirmation: birthdays.count > 1 || nonGregorianBirthdays.count > 1 || imageCount > 1
        )
    }

    func eligibleDefiniteClusters(_ clusters: [PersonCluster], preferredContainerID: String) -> [PersonCluster] {
        clusters.filter {
            $0.confidence == .definite &&
            !$0.hasHardConflict &&
            !mergePreview(for: $0, preferredContainerID: preferredContainerID).requiresExplicitConflictConfirmation
        }
    }

    func merge(
        cluster: PersonCluster,
        preferredContainerID: String,
        allowWithoutNotesEntitlement: Bool,
        confirmScalarConflicts: Bool
    ) throws -> OperationRecord {
        guard cluster.contacts.count > 1 else { throw MaintenanceError.invalidCluster }
        let notesAccess = probeNotesAccess()
        if !notesAccess && !allowWithoutNotesEntitlement { throw MaintenanceError.notesAccessUnavailable }

        let keys = Self.mergeKeys(includeNote: notesAccess)
        let fresh = try fetchRawContacts(ids: cluster.contacts.map(\.id), keys: keys)
        guard fresh.count == cluster.contacts.count else {
            throw MaintenanceError.contactNotFound("Kaynak kayıtlardan biri senkronizasyon sırasında değişti")
        }

        let freshSnapshots = try snapshotsFromFreshContacts(fresh, previous: cluster.contacts, includeNote: notesAccess)
        let freshCluster = PersonCluster(id: cluster.id, contacts: freshSnapshots, confidence: cluster.confidence, evidence: cluster.evidence, hasHardConflict: cluster.hasHardConflict)
        let preview = mergePreview(for: freshCluster, preferredContainerID: preferredContainerID)
        if preview.requiresExplicitConflictConfirmation && !confirmScalarConflicts {
            throw MaintenanceError.scalarConflict(preview.warnings.joined(separator: " "))
        }

        _ = try createFullBackup(from: freshSnapshots)

        let targetContact = fresh.first(where: { containerIdentifier(for: $0.identifier) == preferredContainerID })
        let originalTargetSnapshot = targetContact.flatMap { target in freshSnapshots.first(where: { $0.id == target.identifier }) }
        let master = (targetContact?.mutableCopy() as? CNMutableContact) ?? CNMutableContact()
        let masterWasCreated = targetContact == nil
        applyMergedValues(from: fresh, to: master, includeNote: notesAccess)

        var masterWritten = false
        var operationRecorded = false
        do {
            let save = CNSaveRequest()
            if masterWasCreated { save.add(master, toContainerWithIdentifier: preferredContainerID) }
            else { save.update(master) }
            try store.execute(save)
            masterWritten = true

            let masterID = master.identifier
            guard !masterID.isEmpty, let verified = try fetchRawContacts(ids: [masterID], keys: keys).first else {
                throw MaintenanceError.verificationFailed("Master kayıt yeniden okunamadı")
            }
            try verify(sources: fresh, destination: verified, includeNote: notesAccess)
            try migrateGroups(from: freshSnapshots.flatMap(\.groups), to: master, containerID: preferredContainerID)

            let redundant = fresh.filter { $0.identifier != masterID }
            let record = OperationRecord(
                id: UUID(), kind: .merge, createdAt: Date(), masterIdentifier: masterID,
                masterContainerIdentifier: preferredContainerID, masterWasCreated: masterWasCreated,
                originals: freshSnapshots, deletedIdentifiers: redundant.map(\.identifier)
            )

            try appendOperation(record)
            operationRecorded = true

            if !redundant.isEmpty {
                let deleteRequest = CNSaveRequest()
                redundant.forEach { deleteRequest.delete($0.mutableCopy() as! CNMutableContact) }
                try store.execute(deleteRequest)
            }
            return record
        } catch {
            if operationRecorded { try? removeOperationForRollback(masterID: master.identifier) }
            if masterWritten {
                try? rollbackMasterAfterFailedMerge(
                    masterIdentifier: master.identifier,
                    masterWasCreated: masterWasCreated,
                    originalTarget: originalTargetSnapshot,
                    includeNote: notesAccess
                )
            }
            throw error
        }
    }

    private func removeOperationForRollback(masterID: String) throws {
        if let record = operationHistory().first(where: { $0.masterIdentifier == masterID }) {
            try removeOperation(record.id)
        }
    }

    private func rollbackMasterAfterFailedMerge(masterIdentifier: String, masterWasCreated: Bool, originalTarget: ContactSnapshot?, includeNote: Bool) throws {
        let keys = Self.mergeKeys(includeNote: includeNote)
        guard let current = try fetchRawContacts(ids: [masterIdentifier], keys: keys).first else { return }
        let request = CNSaveRequest()
        if masterWasCreated {
            request.delete(current.mutableCopy() as! CNMutableContact)
        } else if let originalTarget {
            let mutable = current.mutableCopy() as! CNMutableContact
            apply(snapshot: originalTarget, to: mutable, includeNote: includeNote)
            request.update(mutable)
        }
        try store.execute(request)
    }

    func migrateToICloud(snapshot: ContactSnapshot, preferredContainerID: String, allowWithoutNotesEntitlement: Bool) throws -> OperationRecord? {
        guard snapshot.source.id != preferredContainerID else { return nil }
        let notesAccess = probeNotesAccess()
        if !notesAccess && !allowWithoutNotesEntitlement { throw MaintenanceError.notesAccessUnavailable }
        let keys = Self.mergeKeys(includeNote: notesAccess)
        guard let source = try fetchRawContacts(ids: [snapshot.id], keys: keys).first else { throw MaintenanceError.contactNotFound(snapshot.id) }
        let freshSnapshot = ContactScanService.snapshot(source, source: snapshot.source, groups: snapshot.groups, includeNote: notesAccess)
        _ = try createFullBackup(from: [freshSnapshot])
        let destination = CNMutableContact()
        copy(contact: source, to: destination, includeNote: notesAccess)
        let create = CNSaveRequest(); create.add(destination, toContainerWithIdentifier: preferredContainerID); try store.execute(create)
        guard !destination.identifier.isEmpty, let verified = try fetchRawContacts(ids: [destination.identifier], keys: keys).first else { throw MaintenanceError.verificationFailed("iCloud kopyası yeniden okunamadı") }
        try verify(sources: [source], destination: verified, includeNote: notesAccess)
        try migrateGroups(from: freshSnapshot.groups, to: destination, containerID: preferredContainerID)
        let delete = CNSaveRequest(); delete.delete(source.mutableCopy() as! CNMutableContact); try store.execute(delete)
        let record = OperationRecord(id: UUID(), kind: .migration, createdAt: Date(), masterIdentifier: destination.identifier, masterContainerIdentifier: preferredContainerID, masterWasCreated: true, originals: [freshSnapshot], deletedIdentifiers: [freshSnapshot.id])
        try appendOperation(record)
        return record
    }

    func safeBulkMerge(
        clusters: [PersonCluster],
        preferredContainerID: String,
        allowWithoutNotesEntitlement: Bool,
        shouldCancel: () -> Bool,
        progress: (Int, Int, String) -> Void
    ) -> BulkMergeSummary {
        let eligible = eligibleDefiniteClusters(clusters, preferredContainerID: preferredContainerID)
        var success = 0
        var failed = 0
        var attempted = 0
        var failures: [String] = []
        var cancelled = false

        for (index, cluster) in eligible.enumerated() {
            if shouldCancel() { cancelled = true; break }
            attempted += 1
            progress(index + 1, eligible.count, cluster.title)
            do {
                _ = try merge(cluster: cluster, preferredContainerID: preferredContainerID, allowWithoutNotesEntitlement: allowWithoutNotesEntitlement, confirmScalarConflicts: false)
                success += 1
            } catch {
                failed += 1
                failures.append("\(cluster.title): \(error.localizedDescription)")
            }
        }

        return BulkMergeSummary(eligibleCount: eligible.count, attemptedCount: attempted, successCount: success, failedCount: failed, cancelled: cancelled, failureMessages: Array(failures.prefix(20)))
    }
}
