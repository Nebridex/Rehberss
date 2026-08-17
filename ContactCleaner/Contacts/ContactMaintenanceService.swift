import Contacts
import Foundation

final class ContactMaintenanceService {
    enum MaintenanceError: LocalizedError {
        case iCloudContainerNotFound
        case contactNotFound(String)
        case verificationFailed(String)
        case backupFailed
        case notesAccessUnavailable
        case invalidCluster
        case scalarConflict(String)

        var errorDescription: String? {
            switch self {
            case .iCloudContainerNotFound: return "Yazılabilir bir iCloud rehber kaynağı bulunamadı."
            case .contactNotFound(let id): return "Kişi bulunamadı: \(id)"
            case .verificationFailed(let detail): return "Birleştirme doğrulanamadı: \(detail)"
            case .backupFailed: return "Rehber yedeği oluşturulamadı."
            case .notesAccessUnavailable: return "Notes erişimi yok. Güvenli silme için Apple Contacts Notes entitlement gerekir."
            case .invalidCluster: return "Bu eşleşme güvenli bir merge planına dönüştürülemedi."
            case .scalarConflict(let detail): return "Önce çakışmayı onayla: \(detail)"
            }
        }
    }

    enum OperationKind: String, Codable {
        case merge
        case migration
    }

    struct OperationRecord: Codable, Identifiable {
        let id: UUID
        let kind: OperationKind
        let createdAt: Date
        let masterIdentifier: String
        let masterContainerIdentifier: String
        let masterWasCreated: Bool
        let originals: [ContactSnapshot]
        let deletedIdentifiers: [String]
    }

    struct BackupManifest: Codable {
        let createdAt: Date
        let contacts: [ContactSnapshot]
    }

    private let store: CNContactStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var backupDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RehberssBackups", isDirectory: true)
    }

    var journalURL: URL { backupDirectoryURL.appendingPathComponent("operations.json") }

    func probeNotesAccess() -> Bool {
        do {
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor, CNContactNoteKey as CNKeyDescriptor])
            request.unifyResults = false
            request.sortOrder = .none
            var succeeded = false
            try store.enumerateContacts(with: request) { contact, stop in
                _ = contact.note
                succeeded = true
                stop.pointee = true
            }
            return succeeded
        } catch {
            return false
        }
    }

    @discardableResult
    func createFullBackup(from contacts: [ContactSnapshot]) throws -> URL {
        try ensureBackupDirectory()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let jsonURL = backupDirectoryURL.appendingPathComponent("contacts-\(stamp).json")
        let data = try encoder.encode(BackupManifest(createdAt: Date(), contacts: contacts))
        try data.write(to: jsonURL, options: .atomic)

        let vCardContacts = contacts.map { snapshot -> CNMutableContact in
            let contact = CNMutableContact()
            apply(snapshot: snapshot, to: contact, includeNote: snapshot.note != nil)
            return contact
        }
        if let vCardData = try? CNContactVCardSerialization.data(with: vCardContacts) {
            try? vCardData.write(to: backupDirectoryURL.appendingPathComponent("contacts-\(stamp).vcf"), options: .atomic)
        }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else { throw MaintenanceError.backupFailed }
        return jsonURL
    }

    func operationHistory() -> [OperationRecord] {
        guard let data = try? Data(contentsOf: journalURL),
              let records = try? decoder.decode([OperationRecord].self, from: data) else { return [] }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func preferredICloudContainerIdentifier(from contacts: [ContactSnapshot]) throws -> String {
        let grouped = Dictionary(grouping: contacts.filter { $0.source.kind == .iCloud }, by: { $0.source.id })
        if let best = grouped.max(by: { $0.value.count < $1.value.count })?.key { return best }

        let containers = try store.containers(matching: nil)
        if let container = containers.first(where: { $0.name.lowercased().contains("icloud") }) {
            return container.identifier
        }
        throw MaintenanceError.iCloudContainerNotFound
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

    func merge(
        cluster: PersonCluster,
        preferredContainerID: String,
        allowWithoutNotesEntitlement: Bool,
        confirmScalarConflicts: Bool
    ) throws -> OperationRecord {
        guard cluster.contacts.count > 1 else { throw MaintenanceError.invalidCluster }
        let notesAccess = probeNotesAccess()
        if !notesAccess && !allowWithoutNotesEntitlement { throw MaintenanceError.notesAccessUnavailable }

        let preview = mergePreview(for: cluster, preferredContainerID: preferredContainerID)
        if preview.requiresExplicitConflictConfirmation && !confirmScalarConflicts {
            throw MaintenanceError.scalarConflict(preview.warnings.joined(separator: " "))
        }

        _ = try createFullBackup(from: cluster.contacts)
        let keys = Self.mergeKeys(includeNote: notesAccess)
        let fresh = try fetchRawContacts(ids: cluster.contacts.map(\.id), keys: keys)
        guard fresh.count == cluster.contacts.count else {
            throw MaintenanceError.contactNotFound("Kaynak kayıtlardan biri senkronizasyon sırasında değişti")
        }

        let targetContact = fresh.first(where: { containerIdentifier(for: $0.identifier) == preferredContainerID })
        let master = (targetContact?.mutableCopy() as? CNMutableContact) ?? CNMutableContact()
        let masterWasCreated = targetContact == nil
        applyMergedValues(from: fresh, to: master, includeNote: notesAccess)

        let save = CNSaveRequest()
        if masterWasCreated { save.add(master, toContainerWithIdentifier: preferredContainerID) }
        else { save.update(master) }
        try store.execute(save)

        let masterID = master.identifier
        guard !masterID.isEmpty,
              let verified = try fetchRawContacts(ids: [masterID], keys: keys).first else {
            throw MaintenanceError.verificationFailed("Master kayıt yeniden okunamadı")
        }
        try verify(sources: fresh, destination: verified, includeNote: notesAccess)
        try migrateGroups(from: cluster.contacts.flatMap(\.groups), to: master, containerID: preferredContainerID)

        let redundant = fresh.filter { $0.identifier != masterID }
        if !redundant.isEmpty {
            let deleteRequest = CNSaveRequest()
            redundant.forEach { deleteRequest.delete($0.mutableCopy() as! CNMutableContact) }
            try store.execute(deleteRequest)
        }

        let record = OperationRecord(
            id: UUID(),
            kind: .merge,
            createdAt: Date(),
            masterIdentifier: masterID,
            masterContainerIdentifier: preferredContainerID,
            masterWasCreated: masterWasCreated,
            originals: cluster.contacts,
            deletedIdentifiers: redundant.map(\.identifier)
        )
        try appendOperation(record)
        return record
    }

    func migrateToICloud(
        snapshot: ContactSnapshot,
        preferredContainerID: String,
        allowWithoutNotesEntitlement: Bool
    ) throws -> OperationRecord? {
        guard snapshot.source.id != preferredContainerID else { return nil }
        let notesAccess = probeNotesAccess()
        if !notesAccess && !allowWithoutNotesEntitlement { throw MaintenanceError.notesAccessUnavailable }

        _ = try createFullBackup(from: [snapshot])
        let keys = Self.mergeKeys(includeNote: notesAccess)
        guard let source = try fetchRawContacts(ids: [snapshot.id], keys: keys).first else {
            throw MaintenanceError.contactNotFound(snapshot.id)
        }

        let destination = CNMutableContact()
        copy(contact: source, to: destination, includeNote: notesAccess)
        let create = CNSaveRequest()
        create.add(destination, toContainerWithIdentifier: preferredContainerID)
        try store.execute(create)

        guard !destination.identifier.isEmpty,
              let verified = try fetchRawContacts(ids: [destination.identifier], keys: keys).first else {
            throw MaintenanceError.verificationFailed("iCloud kopyası yeniden okunamadı")
        }
        try verify(sources: [source], destination: verified, includeNote: notesAccess)
        try migrateGroups(from: snapshot.groups, to: destination, containerID: preferredContainerID)

        let delete = CNSaveRequest()
        delete.delete(source.mutableCopy() as! CNMutableContact)
        try store.execute(delete)

        let record = OperationRecord(
            id: UUID(),
            kind: .migration,
            createdAt: Date(),
            masterIdentifier: destination.identifier,
            masterContainerIdentifier: preferredContainerID,
            masterWasCreated: true,
            originals: [snapshot],
            deletedIdentifiers: [snapshot.id]
        )
        try appendOperation(record)
        return record
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

    func safeBulkMerge(
        clusters: [PersonCluster],
        preferredContainerID: String,
        allowWithoutNotesEntitlement: Bool,
        progress: (Int, Int) -> Void
    ) -> [Result<OperationRecord, Error>] {
        let eligible = clusters.filter {
            $0.confidence == .definite && !$0.hasHardConflict && !mergePreview(for: $0, preferredContainerID: preferredContainerID).requiresExplicitConflictConfirmation
        }
        return eligible.enumerated().map { index, cluster in
            progress(index + 1, eligible.count)
            return Result {
                try merge(
                    cluster: cluster,
                    preferredContainerID: preferredContainerID,
                    allowWithoutNotesEntitlement: allowWithoutNotesEntitlement,
                    confirmScalarConflicts: false
                )
            }
        }
    }

    private func fetchRawContacts(ids: [String], keys: [CNKeyDescriptor]) throws -> [CNContact] {
        guard !ids.isEmpty else { return [] }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = false
        request.sortOrder = .none
        request.predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        var found: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in found.append(contact) }
        return found
    }

    private func containerIdentifier(for contactID: String) -> String? {
        try? store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: contactID)).first?.identifier
    }

    private func applyMergedValues(from contacts: [CNContact], to target: CNMutableContact, includeNote: Bool) {
        target.namePrefix = preferredString(target.namePrefix, values: contacts.map(\.namePrefix))
        target.givenName = preferredString(target.givenName, values: contacts.map(\.givenName))
        target.middleName = preferredString(target.middleName, values: contacts.map(\.middleName))
        target.familyName = preferredString(target.familyName, values: contacts.map(\.familyName))
        target.previousFamilyName = preferredString(target.previousFamilyName, values: contacts.map(\.previousFamilyName))
        target.nameSuffix = preferredString(target.nameSuffix, values: contacts.map(\.nameSuffix))
        target.nickname = preferredString(target.nickname, values: contacts.map(\.nickname))
        target.phoneticGivenName = preferredString(target.phoneticGivenName, values: contacts.map(\.phoneticGivenName))
        target.phoneticMiddleName = preferredString(target.phoneticMiddleName, values: contacts.map(\.phoneticMiddleName))
        target.phoneticFamilyName = preferredString(target.phoneticFamilyName, values: contacts.map(\.phoneticFamilyName))

        target.organizationName = combinedDistinct(contacts.map(\.organizationName), preferred: target.organizationName)
        target.departmentName = combinedDistinct(contacts.map(\.departmentName), preferred: target.departmentName)
        target.jobTitle = combinedDistinct(contacts.map(\.jobTitle), preferred: target.jobTitle)

        target.phoneNumbers = unionLabeled(contacts.flatMap(\.phoneNumbers)) { PhoneNormalizer.normalize($0.value.stringValue) }
        target.emailAddresses = unionLabeled(contacts.flatMap(\.emailAddresses)) { EmailNormalizer.normalize(String($0.value)) }
        target.postalAddresses = unionLabeled(contacts.flatMap(\.postalAddresses)) { postalKey($0.value) }
        target.urlAddresses = unionLabeled(contacts.flatMap(\.urlAddresses)) { String($0.value).lowercased() }
        target.contactRelations = unionLabeled(contacts.flatMap(\.contactRelations)) { $0.value.name.lowercased() }
        target.socialProfiles = unionLabeled(contacts.flatMap(\.socialProfiles)) { "\($0.value.service)|\($0.value.username)|\($0.value.urlString)".lowercased() }
        target.instantMessageAddresses = unionLabeled(contacts.flatMap(\.instantMessageAddresses)) { "\($0.value.service)|\($0.value.username)".lowercased() }
        target.dates = unionLabeled(contacts.flatMap(\.dates)) { dateKey($0.value as DateComponents) }

        if target.birthday == nil { target.birthday = contacts.compactMap(\.birthday).first }
        if target.nonGregorianBirthday == nil { target.nonGregorianBirthday = contacts.compactMap(\.nonGregorianBirthday).first }
        if target.imageData == nil, let image = contacts.compactMap(\.imageData).max(by: { $0.count < $1.count }) { target.imageData = image }
        if includeNote {
            let notes = nonEmptyUnique(contacts.map(\.note))
            if !notes.isEmpty { target.note = notes.joined(separator: "\n\n---\n\n") }
        }
    }

    private func copy(contact: CNContact, to target: CNMutableContact, includeNote: Bool) {
        target.namePrefix = contact.namePrefix
        target.givenName = contact.givenName
        target.middleName = contact.middleName
        target.familyName = contact.familyName
        target.previousFamilyName = contact.previousFamilyName
        target.nameSuffix = contact.nameSuffix
        target.nickname = contact.nickname
        target.phoneticGivenName = contact.phoneticGivenName
        target.phoneticMiddleName = contact.phoneticMiddleName
        target.phoneticFamilyName = contact.phoneticFamilyName
        target.organizationName = contact.organizationName
        target.departmentName = contact.departmentName
        target.jobTitle = contact.jobTitle
        target.phoneNumbers = contact.phoneNumbers
        target.emailAddresses = contact.emailAddresses
        target.postalAddresses = contact.postalAddresses
        target.urlAddresses = contact.urlAddresses
        target.contactRelations = contact.contactRelations
        target.socialProfiles = contact.socialProfiles
        target.instantMessageAddresses = contact.instantMessageAddresses
        target.dates = contact.dates
        target.birthday = contact.birthday
        target.nonGregorianBirthday = contact.nonGregorianBirthday
        target.imageData = contact.imageData
        if includeNote { target.note = contact.note }
    }

    private func apply(snapshot: ContactSnapshot, to target: CNMutableContact, includeNote: Bool) {
        target.namePrefix = snapshot.namePrefix
        target.givenName = snapshot.givenName
        target.middleName = snapshot.middleName
        target.familyName = snapshot.familyName
        target.previousFamilyName = snapshot.previousFamilyName
        target.nameSuffix = snapshot.nameSuffix
        target.nickname = snapshot.nickname
        target.phoneticGivenName = snapshot.phoneticGivenName
        target.phoneticMiddleName = snapshot.phoneticMiddleName
        target.phoneticFamilyName = snapshot.phoneticFamilyName
        target.organizationName = snapshot.organizationName
        target.departmentName = snapshot.departmentName
        target.jobTitle = snapshot.jobTitle
        target.phoneNumbers = snapshot.phones.map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
        target.emailAddresses = snapshot.emails.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        target.postalAddresses = snapshot.postalAddresses.map {
            let address = CNMutablePostalAddress()
            address.street = $0.street
            address.subLocality = $0.subLocality
            address.city = $0.city
            address.subAdministrativeArea = $0.subAdministrativeArea
            address.state = $0.state
            address.postalCode = $0.postalCode
            address.country = $0.country
            address.isoCountryCode = $0.isoCountryCode
            return CNLabeledValue(label: $0.label, value: address.copy() as! CNPostalAddress)
        }
        target.urlAddresses = snapshot.urlAddresses.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        target.contactRelations = snapshot.relations.map { CNLabeledValue(label: $0.label, value: CNContactRelation(name: $0.value)) }
        target.dates = snapshot.dates.map { CNLabeledValue(label: $0.label, value: $0.components as NSDateComponents) }
        target.socialProfiles = snapshot.socialProfiles.map {
            CNLabeledValue(label: $0.label, value: CNSocialProfile(urlString: $0.urlString, username: $0.username, userIdentifier: $0.userIdentifier, service: $0.service))
        }
        target.instantMessageAddresses = snapshot.instantMessages.map {
            CNLabeledValue(label: $0.label, value: CNInstantMessageAddress(username: $0.username, service: $0.service))
        }
        target.birthday = snapshot.birthday
        target.nonGregorianBirthday = snapshot.nonGregorianBirthday
        target.imageData = snapshot.imageData
        if includeNote, let note = snapshot.note { target.note = note }
    }

    private func verify(sources: [CNContact], destination: CNContact, includeNote: Bool) throws {
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

    private func migrateGroups(from groups: [ContactGroupSnapshot], to contact: CNMutableContact, containerID: String) throws {
        let names = nonEmptyUnique(groups.map(\.name))
        guard !names.isEmpty else { return }
        for name in names {
            let group = try findOrCreateGroup(named: name, containerID: containerID)
            let request = CNSaveRequest()
            request.addMember(contact, to: group)
            try store.execute(request)
        }
    }

    private func restoreGroups(_ groups: [ContactGroupSnapshot], to contact: CNMutableContact, originalContainerID: String) throws {
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

    private func findOrCreateGroup(named name: String, containerID: String) throws -> CNGroup {
        let groups = try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: containerID))
        if let existing = groups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let mutable = CNMutableGroup()
        mutable.name = name
        let request = CNSaveRequest()
        request.add(mutable, toContainerWithIdentifier: containerID)
        try store.execute(request)
        return mutable
    }

    private static func mergeKeys(includeNote: Bool) -> [CNKeyDescriptor] {
        ContactScanService.readKeys(includeNote: includeNote)
    }

    private func ensureBackupDirectory() throws {
        try FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
    }

    private func appendOperation(_ record: OperationRecord) throws {
        try ensureBackupDirectory()
        var history = operationHistory()
        history.append(record)
        try encoder.encode(history).write(to: journalURL, options: .atomic)
    }

    private func removeOperation(_ id: UUID) throws {
        var history = operationHistory()
        history.removeAll { $0.id == id }
        try encoder.encode(history).write(to: journalURL, options: .atomic)
    }

    private func preferredString(_ preferred: String, values: [String]) -> String {
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return preferred }
        return nonEmptyUnique(values).max(by: { $0.count < $1.count }) ?? ""
    }

    private func combinedDistinct(_ values: [String], preferred: String) -> String {
        var ordered: [String] = []
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ordered.append(preferred) }
        for value in nonEmptyUnique(values) where !ordered.contains(value) { ordered.append(value) }
        return ordered.joined(separator: " / ")
    }

    private func bestName(_ contacts: [ContactSnapshot]) -> String {
        contacts.map(\.displayName).filter { $0 != "İsimsiz Kayıt" }.max(by: { $0.count < $1.count }) ?? "İsimsiz Kayıt"
    }

    private func nonEmptyUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            let key = trimmed.lowercased()
            return seen.insert(key).inserted
        }
    }

    private func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter {
            let k = key($0)
            guard !k.isEmpty else { return false }
            return seen.insert(k).inserted
        }
    }

    private func unionLabeled<T>(_ values: [CNLabeledValue<T>], key: (CNLabeledValue<T>) -> String) -> [CNLabeledValue<T>] {
        unique(values, key: key)
    }

    private func uniqueDates(_ values: [DateComponents]) -> [DateComponents] {
        unique(values, key: dateKey)
    }

    private func dateKey(_ value: DateComponents) -> String {
        "\(value.era ?? -1)|\(value.year ?? -1)|\(value.month ?? -1)|\(value.day ?? -1)"
    }

    private func postalKey(_ value: CNPostalAddress) -> String {
        [value.street, value.subLocality, value.city, value.subAdministrativeArea, value.state, value.postalCode, value.country, value.isoCountryCode]
            .joined(separator: "|").lowercased()
    }
}

struct MergePreview: Identifiable, Hashable {
    var id: String { clusterID }
    let clusterID: String
    let targetContactID: String?
    let targetContainerID: String
    let displayName: String
    let phones: [LabeledString]
    let emails: [LabeledString]
    let organizationName: String
    let departmentName: String
    let jobTitle: String
    let selectedBirthday: DateComponents?
    let warnings: [String]
    let requiresExplicitConflictConfirmation: Bool
}
