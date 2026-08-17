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

        var errorDescription: String? {
            switch self {
            case .iCloudContainerNotFound: return "Yazılabilir bir iCloud rehber kaynağı bulunamadı."
            case .contactNotFound(let id): return "Kişi bulunamadı: \(id)"
            case .verificationFailed(let detail): return "Birleştirme doğrulanamadı: \(detail)"
            case .backupFailed: return "Rehber yedeği oluşturulamadı."
            case .notesAccessUnavailable: return "Notes erişimi yok. Güvenli silme için Apple Contacts Notes entitlement gerekir."
            case .invalidCluster: return "Bu eşleşme güvenli bir merge planına dönüştürülemedi."
            }
        }
    }

    struct OperationRecord: Codable, Identifiable {
        let id: UUID
        let createdAt: Date
        let masterIdentifier: String
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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("RehberssBackups", isDirectory: true)
    }

    var journalURL: URL { backupDirectoryURL.appendingPathComponent("operations.json") }

    func probeNotesAccess() -> Bool {
        do {
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor, CNContactNoteKey as CNKeyDescriptor])
            request.unifyResults = false
            request.sortOrder = .none
            var readOne = false
            try store.enumerateContacts(with: request) { contact, stop in
                _ = contact.note
                readOne = true
                stop.pointee = true
            }
            return readOne || CNContactStore.authorizationStatus(for: .contacts) == .authorized
        } catch {
            return false
        }
    }

    @discardableResult
    func createFullBackup(from contacts: [ContactSnapshot]) throws -> URL {
        try ensureBackupDirectory()
        let formatter = ISO8601DateFormatter()
        let safeStamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = backupDirectoryURL.appendingPathComponent("contacts-\(safeStamp).json")
        let data = try encoder.encode(BackupManifest(createdAt: Date(), contacts: contacts))
        try data.write(to: url, options: .atomic)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MaintenanceError.backupFailed }
        return url
    }

    func operationHistory() -> [OperationRecord] {
        guard let data = try? Data(contentsOf: journalURL), let items = try? decoder.decode([OperationRecord].self, from: data) else { return [] }
        return items.sorted { $0.createdAt > $1.createdAt }
    }

    func preferredICloudContainerIdentifier(from contacts: [ContactSnapshot]) throws -> String {
        let iCloudSources = Dictionary(grouping: contacts.filter { $0.source.kind == .iCloud }, by: { $0.source.id })
        if let best = iCloudSources.max(by: { $0.value.count < $1.value.count })?.key { return best }

        let containers = try store.containers(matching: nil)
        if let container = containers.first(where: {
            let name = $0.name.lowercased()
            return name.contains("icloud") || ($0.type == .cardDAV && name.contains("icloud"))
        }) { return container.identifier }
        throw MaintenanceError.iCloudContainerNotFound
    }

    func mergePreview(for cluster: PersonCluster, preferredContainerID: String) -> MergePreview {
        let target = cluster.contacts.first(where: { $0.source.id == preferredContainerID }) ?? cluster.contacts.first
        let allPhones = unique(cluster.contacts.flatMap(\.phones)) { PhoneNormalizer.normalize($0.value) }
        let allEmails = unique(cluster.contacts.flatMap(\.emails)) { EmailNormalizer.normalize($0.value) }
        let organizations = nonEmptyUnique(cluster.contacts.map(\.organizationName))
        let departments = nonEmptyUnique(cluster.contacts.map(\.departmentName))
        let titles = nonEmptyUnique(cluster.contacts.map(\.jobTitle))
        let birthdays = Array(Set(cluster.contacts.compactMap(\.birthday).map(Self.dateKey)))

        return MergePreview(
            clusterID: cluster.id,
            targetContactID: target?.id,
            targetContainerID: preferredContainerID,
            displayName: bestName(cluster.contacts),
            phones: allPhones,
            emails: allEmails,
            organizationName: organizations.first ?? "",
            departmentName: departments.first ?? "",
            jobTitle: titles.first ?? "",
            conflictMessages: [
                organizations.count > 1 ? "Birden fazla şirket bilgisi var: \(organizations.joined(separator: " / "))" : nil,
                departments.count > 1 ? "Birden fazla departman bilgisi var: \(departments.joined(separator: " / "))" : nil,
                titles.count > 1 ? "Birden fazla unvan bilgisi var: \(titles.joined(separator: " / "))" : nil,
                birthdays.count > 1 ? "Doğum günü bilgileri çakışıyor." : nil
            ].compactMap { $0 }
        )
    }

    func merge(cluster: PersonCluster, preferredContainerID: String, allowWithoutNotesEntitlement: Bool) throws -> OperationRecord {
        guard cluster.contacts.count > 1 else { throw MaintenanceError.invalidCluster }
        if !probeNotesAccess() && !allowWithoutNotesEntitlement { throw MaintenanceError.notesAccessUnavailable }

        _ = try createFullBackup(from: cluster.contacts)
        let keys = Self.mergeKeys(includeNote: probeNotesAccess())
        let fresh = try fetchRawContacts(ids: cluster.contacts.map(\.id), keys: keys)
        guard fresh.count == cluster.contacts.count else { throw MaintenanceError.contactNotFound("Kaynak kayıtlardan biri senkronizasyon sırasında değişti") }

        let targetContact = fresh.first(where: { containerIdentifier(for: $0.identifier) == preferredContainerID })
        let master: CNMutableContact
        let masterWasCreated: Bool
        if let targetContact {
            master = targetContact.mutableCopy() as! CNMutableContact
            masterWasCreated = false
        } else {
            master = CNMutableContact()
            masterWasCreated = true
        }

        applyMergedValues(from: fresh, to: master, includeNote: probeNotesAccess())

        let save = CNSaveRequest()
        if masterWasCreated {
            save.add(master, toContainerWithIdentifier: preferredContainerID)
        } else {
            save.update(master)
        }
        try store.execute(save)

        let masterID = master.identifier
        let verified = try fetchRawContacts(ids: [masterID], keys: keys).first
        guard let verified else { throw MaintenanceError.verificationFailed("Master kayıt yeniden okunamadı") }
        try verify(sources: fresh, destination: verified, includeNote: probeNotesAccess())

        let redundant = fresh.filter { $0.identifier != masterID }
        if !redundant.isEmpty {
            let deleteRequest = CNSaveRequest()
            for contact in redundant {
                deleteRequest.delete(contact.mutableCopy() as! CNMutableContact)
            }
            try store.execute(deleteRequest)
        }

        let record = OperationRecord(
            id: UUID(),
            createdAt: Date(),
            masterIdentifier: masterID,
            masterWasCreated: masterWasCreated,
            originals: cluster.contacts,
            deletedIdentifiers: redundant.map(\.identifier)
        )
        try appendOperation(record)
        return record
    }

    func undo(_ operation: OperationRecord) throws {
        let keys = Self.mergeKeys(includeNote: probeNotesAccess())
        let currentMaster = try fetchRawContacts(ids: [operation.masterIdentifier], keys: keys).first
        let originalMaster = operation.originals.first(where: { $0.id == operation.masterIdentifier })
        let request = CNSaveRequest()

        if operation.masterWasCreated {
            if let currentMaster { request.delete(currentMaster.mutableCopy() as! CNMutableContact) }
        } else if let currentMaster, let originalMaster {
            let mutable = currentMaster.mutableCopy() as! CNMutableContact
            apply(snapshot: originalMaster, to: mutable)
            request.update(mutable)
        }

        for snapshot in operation.originals where snapshot.id != operation.masterIdentifier {
            let recreated = CNMutableContact()
            apply(snapshot: snapshot, to: recreated)
            request.add(recreated, toContainerWithIdentifier: snapshot.source.id)
        }

        try store.execute(request)
        try removeOperation(operation.id)
    }

    func safeBulkMerge(clusters: [PersonCluster], preferredContainerID: String, allowWithoutNotesEntitlement: Bool, progress: (Int, Int) -> Void) -> [Result<OperationRecord, Error>] {
        let eligible = clusters.filter { $0.confidence == .definite && !$0.hasHardConflict }
        return eligible.enumerated().map { index, cluster in
            progress(index + 1, eligible.count)
            return Result { try merge(cluster: cluster, preferredContainerID: preferredContainerID, allowWithoutNotesEntitlement: allowWithoutNotesEntitlement) }
        }
    }

    private func fetchRawContacts(ids: [String], keys: [CNKeyDescriptor]) throws -> [CNContact] {
        guard !ids.isEmpty else { return [] }
        let predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        return try store.unifiedContacts(matching: predicate, keysToFetch: keys)
    }

    private func containerIdentifier(for contactID: String) -> String? {
        (try? store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: contactID)))?.first?.identifier
    }

    private func applyMergedValues(from contacts: [CNContact], to target: CNMutableContact, includeNote: Bool) {
        target.namePrefix = bestString(contacts.map(\.namePrefix), fallback: target.namePrefix)
        target.givenName = bestString(contacts.map(\.givenName), fallback: target.givenName)
        target.middleName = bestString(contacts.map(\.middleName), fallback: target.middleName)
        target.familyName = bestString(contacts.map(\.familyName), fallback: target.familyName)
        target.previousFamilyName = bestString(contacts.map(\.previousFamilyName), fallback: target.previousFamilyName)
        target.nameSuffix = bestString(contacts.map(\.nameSuffix), fallback: target.nameSuffix)
        target.nickname = bestString(contacts.map(\.nickname), fallback: target.nickname)
        target.phoneticGivenName = bestString(contacts.map(\.phoneticGivenName), fallback: target.phoneticGivenName)
        target.phoneticMiddleName = bestString(contacts.map(\.phoneticMiddleName), fallback: target.phoneticMiddleName)
        target.phoneticFamilyName = bestString(contacts.map(\.phoneticFamilyName), fallback: target.phoneticFamilyName)
        target.organizationName = bestString(contacts.map(\.organizationName), fallback: target.organizationName)
        target.departmentName = bestString(contacts.map(\.departmentName), fallback: target.departmentName)
        target.jobTitle = bestString(contacts.map(\.jobTitle), fallback: target.jobTitle)

        target.phoneNumbers = unionLabeled(contacts.flatMap(\.phoneNumbers)) { PhoneNormalizer.normalize($0.value.stringValue) }
        target.emailAddresses = unionLabeled(contacts.flatMap(\.emailAddresses)) { EmailNormalizer.normalize(String($0.value)) }
        target.postalAddresses = unionLabeled(contacts.flatMap(\.postalAddresses)) { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress).lowercased() }
        target.urlAddresses = unionLabeled(contacts.flatMap(\.urlAddresses)) { String($0.value).lowercased() }
        target.contactRelations = unionLabeled(contacts.flatMap(\.contactRelations)) { $0.value.name.lowercased() }
        target.socialProfiles = unionLabeled(contacts.flatMap(\.socialProfiles)) { "\($0.value.service)|\($0.value.username)|\($0.value.urlString)".lowercased() }
        target.instantMessageAddresses = unionLabeled(contacts.flatMap(\.instantMessageAddresses)) { "\($0.value.service)|\($0.value.username)".lowercased() }
        target.dates = unionLabeled(contacts.flatMap(\.dates)) { Self.dateKey($0.value as DateComponents) }

        target.birthday = consistentDate(contacts.compactMap(\.birthday)) ?? target.birthday
        target.nonGregorianBirthday = consistentDate(contacts.compactMap(\.nonGregorianBirthday)) ?? target.nonGregorianBirthday
        if let image = contacts.compactMap(\.imageData).max(by: { $0.count < $1.count }) { target.imageData = image }
        if includeNote {
            let notes = nonEmptyUnique(contacts.map(\.note))
            if !notes.isEmpty { target.note = notes.joined(separator: "\n\n---\n\n") }
        }
    }

    private func apply(snapshot: ContactSnapshot, to target: CNMutableContact) {
        target.givenName = snapshot.givenName
        target.middleName = snapshot.middleName
        target.familyName = snapshot.familyName
        target.nickname = snapshot.nickname
        target.organizationName = snapshot.organizationName
        target.departmentName = snapshot.departmentName
        target.jobTitle = snapshot.jobTitle
        target.phoneNumbers = snapshot.phones.map { CNLabeledValue(label: $0.label, value: CNPhoneNumber(stringValue: $0.value)) }
        target.emailAddresses = snapshot.emails.map { CNLabeledValue(label: $0.label, value: $0.value as NSString) }
        target.birthday = snapshot.birthday
    }

    private func verify(sources: [CNContact], destination: CNContact, includeNote: Bool) throws {
        let sourcePhones = Set(sources.flatMap(\.phoneNumbers).map { PhoneNormalizer.normalize($0.value.stringValue) }.filter { !$0.isEmpty })
        let destPhones = Set(destination.phoneNumbers.map { PhoneNormalizer.normalize($0.value.stringValue) }.filter { !$0.isEmpty })
        guard sourcePhones.isSubset(of: destPhones) else { throw MaintenanceError.verificationFailed("Telefonlardan biri master kayıtta yok") }

        let sourceEmails = Set(sources.flatMap(\.emailAddresses).map { EmailNormalizer.normalize(String($0.value)) }.filter { !$0.isEmpty })
        let destEmails = Set(destination.emailAddresses.map { EmailNormalizer.normalize(String($0.value)) }.filter { !$0.isEmpty })
        guard sourceEmails.isSubset(of: destEmails) else { throw MaintenanceError.verificationFailed("E-postalardan biri master kayıtta yok") }

        let sourceURLs = Set(sources.flatMap(\.urlAddresses).map { String($0.value).lowercased() })
        let destURLs = Set(destination.urlAddresses.map { String($0.value).lowercased() })
        guard sourceURLs.isSubset(of: destURLs) else { throw MaintenanceError.verificationFailed("URL alanlarından biri master kayıtta yok") }

        if includeNote {
            let notes = nonEmptyUnique(sources.map(\.note))
            guard notes.allSatisfy({ destination.note.contains($0) }) else { throw MaintenanceError.verificationFailed("Not alanlarından biri korunamadı") }
        }
    }

    private static func mergeKeys(includeNote: Bool) -> [CNKeyDescriptor] {
        var keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPreviousFamilyNameKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactPhoneticGivenNameKey as CNKeyDescriptor,
            CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
            CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor
        ]
        if includeNote { keys.append(CNContactNoteKey as CNKeyDescriptor) }
        return keys
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

    private func bestString(_ values: [String], fallback: String) -> String {
        nonEmptyUnique(values).max(by: { $0.count < $1.count }) ?? fallback
    }

    private func bestName(_ contacts: [ContactSnapshot]) -> String {
        contacts.map(\.displayName).filter { $0 != "İsimsiz Kayıt" }.max(by: { $0.count < $1.count }) ?? "İsimsiz Kayıt"
    }

    private func nonEmptyUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return false }
            return seen.insert(value).inserted
        }
    }

    private func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter {
            let normalized = key($0)
            guard !normalized.isEmpty else { return false }
            return seen.insert(normalized).inserted
        }
    }

    private func unionLabeled<T>(_ values: [CNLabeledValue<T>], key: (CNLabeledValue<T>) -> String) -> [CNLabeledValue<T>] {
        unique(values, key: key)
    }

    private func consistentDate(_ values: [DateComponents]) -> DateComponents? {
        let grouped = Dictionary(grouping: values, by: Self.dateKey)
        guard grouped.keys.count == 1 else { return nil }
        return values.first
    }

    private static func dateKey(_ value: DateComponents) -> String {
        "\(value.calendar?.identifier.debugDescription ?? "")|\(value.era ?? -1)|\(value.year ?? -1)|\(value.month ?? -1)|\(value.day ?? -1)"
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
    let conflictMessages: [String]

    var isConflictFree: Bool { conflictMessages.isEmpty }
}
