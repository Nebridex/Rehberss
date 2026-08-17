import Contacts
import Foundation

extension ContactMaintenanceService {
    func verify(sources: [CNContact], destination: CNContact, includeNote: Bool) throws {
        let sourcePhones = Set(sources.flatMap(\.phoneNumbers).map { PhoneNormalizer.normalize($0.value.stringValue) }.filter { !$0.isEmpty })
        let destPhones = Set(destination.phoneNumbers.map { PhoneNormalizer.normalize($0.value.stringValue) }.filter { !$0.isEmpty })
        guard sourcePhones.isSubset(of: destPhones) else { throw MaintenanceError.verificationFailed("Telefonlardan biri master kayıtta yok") }

        let sourceEmails = Set(sources.flatMap(\.emailAddresses).map { EmailNormalizer.normalize(String($0.value)) }.filter { !$0.isEmpty })
        let destEmails = Set(destination.emailAddresses.map { EmailNormalizer.normalize(String($0.value)) }.filter { !$0.isEmpty })
        guard sourceEmails.isSubset(of: destEmails) else { throw MaintenanceError.verificationFailed("E-postalardan biri master kayıtta yok") }

        let sourceAddresses = Set(sources.flatMap(\.postalAddresses).map { postalKey($0.value) })
        let destAddresses = Set(destination.postalAddresses.map { postalKey($0.value) })
        guard sourceAddresses.isSubset(of: destAddresses) else { throw MaintenanceError.verificationFailed("Adreslerden biri master kayıtta yok") }

        let sourceURLs = Set(sources.flatMap(\.urlAddresses).map { String($0.value).lowercased() })
        let destURLs = Set(destination.urlAddresses.map { String($0.value).lowercased() })
        guard sourceURLs.isSubset(of: destURLs) else { throw MaintenanceError.verificationFailed("URL alanlarından biri master kayıtta yok") }

        let sourceRelations = Set(sources.flatMap(\.contactRelations).map { $0.value.name.lowercased() })
        let destRelations = Set(destination.contactRelations.map { $0.value.name.lowercased() })
        guard sourceRelations.isSubset(of: destRelations) else { throw MaintenanceError.verificationFailed("İlişki alanlarından biri master kayıtta yok") }

        let sourceSocial = Set(sources.flatMap(\.socialProfiles).map { socialKey($0.value) })
        let destSocial = Set(destination.socialProfiles.map { socialKey($0.value) })
        guard sourceSocial.isSubset(of: destSocial) else { throw MaintenanceError.verificationFailed("Sosyal profillerden biri master kayıtta yok") }

        let sourceIM = Set(sources.flatMap(\.instantMessageAddresses).map { instantMessageKey($0.value) })
        let destIM = Set(destination.instantMessageAddresses.map { instantMessageKey($0.value) })
        guard sourceIM.isSubset(of: destIM) else { throw MaintenanceError.verificationFailed("Mesajlaşma hesaplarından biri master kayıtta yok") }

        let sourceDates = Set(sources.flatMap(\.dates).map { dateKey($0.value as DateComponents) })
        let destDates = Set(destination.dates.map { dateKey($0.value as DateComponents) })
        guard sourceDates.isSubset(of: destDates) else { throw MaintenanceError.verificationFailed("Özel tarihlerden biri master kayıtta yok") }

        let sourceBirthdays = Set(sources.compactMap(\.birthday).map(dateKey))
        if sourceBirthdays.count == 1, let only = sourceBirthdays.first {
            guard destination.birthday.map(dateKey) == only else { throw MaintenanceError.verificationFailed("Doğum günü korunamadı") }
        }

        let sourceNonGregorianBirthdays = Set(sources.compactMap(\.nonGregorianBirthday).map(dateKey))
        if sourceNonGregorianBirthdays.count == 1, let only = sourceNonGregorianBirthdays.first {
            guard destination.nonGregorianBirthday.map(dateKey) == only else { throw MaintenanceError.verificationFailed("Alternatif takvim doğum günü korunamadı") }
        }

        for organization in nonEmptyUnique(sources.map(\.organizationName)) {
            guard destination.organizationName.localizedCaseInsensitiveContains(organization) else {
                throw MaintenanceError.verificationFailed("Şirket bilgisi korunamadı")
            }
        }
        for department in nonEmptyUnique(sources.map(\.departmentName)) {
            guard destination.departmentName.localizedCaseInsensitiveContains(department) else {
                throw MaintenanceError.verificationFailed("Departman bilgisi korunamadı")
            }
        }
        for title in nonEmptyUnique(sources.map(\.jobTitle)) {
            guard destination.jobTitle.localizedCaseInsensitiveContains(title) else {
                throw MaintenanceError.verificationFailed("Unvan bilgisi korunamadı")
            }
        }

        if sources.contains(where: { $0.imageData != nil }) && destination.imageData == nil {
            throw MaintenanceError.verificationFailed("Kişi fotoğrafı korunamadı")
        }

        if includeNote {
            let notes = nonEmptyUnique(sources.map(\.note))
            guard notes.allSatisfy({ destination.note.contains($0) }) else {
                throw MaintenanceError.verificationFailed("Not alanlarından biri korunamadı")
            }
        }
    }

    func migrateGroups(from groups: [ContactGroupSnapshot], to contact: CNMutableContact, containerID: String) throws {
        let names = nonEmptyUnique(groups.map(\.name))
        guard !names.isEmpty else { return }
        for name in names {
            let group = try findOrCreateGroup(named: name, containerID: containerID)
            let request = CNSaveRequest()
            request.addMember(contact, to: group)
            try store.execute(request)
        }
    }

    func restoreGroups(_ groups: [ContactGroupSnapshot], to contact: CNMutableContact, originalContainerID: String) throws {
        for item in groups {
            let group: CNGroup
            let existing = try store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [item.id])).first
            if let existing { group = existing }
            else { group = try findOrCreateGroup(named: item.name, containerID: originalContainerID) }
            let request = CNSaveRequest()
            request.addMember(contact, to: group)
            try store.execute(request)
        }
    }

    func findOrCreateGroup(named name: String, containerID: String) throws -> CNGroup {
        let groups = try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: containerID))
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let mutable = CNMutableGroup()
        mutable.name = name
        let request = CNSaveRequest()
        request.add(mutable, toContainerWithIdentifier: containerID)
        try store.execute(request)
        return mutable
    }

    func undo(_ operation: OperationRecord) throws {
        let notesAccess = probeNotesAccess()
        let keys = Self.mergeKeys(includeNote: notesAccess)
        let currentMaster = try fetchRawContacts(ids: [operation.masterIdentifier], keys: keys).first
        let originalMaster = operation.originals.first(where: { $0.id == operation.masterIdentifier })

        if operation.masterWasCreated {
            if let currentMaster {
                let request = CNSaveRequest()
                request.delete(currentMaster.mutableCopy() as! CNMutableContact)
                try store.execute(request)
            }
        } else if let currentMaster, let originalMaster {
            let mutable = currentMaster.mutableCopy() as! CNMutableContact
            apply(snapshot: originalMaster, to: mutable, includeNote: notesAccess)
            let request = CNSaveRequest()
            request.update(mutable)
            try store.execute(request)
        }

        for snapshot in operation.originals where snapshot.id != operation.masterIdentifier || operation.masterWasCreated {
            let recreated = CNMutableContact()
            apply(snapshot: snapshot, to: recreated, includeNote: notesAccess)
            let request = CNSaveRequest()
            request.add(recreated, toContainerWithIdentifier: snapshot.source.id)
            try store.execute(request)
            try restoreGroups(snapshot.groups, to: recreated, originalContainerID: snapshot.source.id)
        }

        try removeOperation(operation.id)
    }
}
