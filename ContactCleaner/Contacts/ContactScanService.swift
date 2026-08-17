@preconcurrency import Contacts
import Foundation

final class ContactScanService: @unchecked Sendable {
    private let store = CNContactStore()

    struct ScanPayload {
        let rawContacts: [ContactSnapshot]
        let unifiedCount: Int
        let notesAccessAvailable: Bool
        let sources: [ContactSource]
        let defaultContainerIdentifier: String?
    }

    func authorizationStatus() -> CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func scan(progress: @escaping (String) -> Void) async throws -> ScanPayload {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [store] in
                do {
                    progress("Kaynak hesaplar bulunuyor")
                    let sources = try self.fetchSources(store: store)
                    let defaultContainerID = store.defaultContainerIdentifier()
                    let notesAccess = self.probeNotesAccess(store: store)
                    progress("Liste ve grup üyelikleri okunuyor")
                    let groupMap = try self.fetchGroupMemberships(store: store, sources: sources)
                    progress("Fiziksel kişi kayıtları okunuyor")
                    var raw: [ContactSnapshot] = []
                    for source in sources {
                        raw.append(contentsOf: try self.fetchContacts(in: source, store: store, groupMap: groupMap, includeNote: notesAccess))
                    }
                    progress("iOS unified kişi görünümü sayılıyor")
                    let unifiedCount = try self.fetchUnifiedCount(store: store)
                    continuation.resume(returning: ScanPayload(rawContacts: raw, unifiedCount: unifiedCount, notesAccessAvailable: notesAccess, sources: sources, defaultContainerIdentifier: defaultContainerID))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func fetchSources(store: CNContactStore) throws -> [ContactSource] {
        try store.containers(matching: nil).map { container in
            ContactSource(id: container.identifier, name: container.name.isEmpty ? "Bilinmeyen Kaynak" : container.name, kind: sourceKind(for: container))
        }
    }

    private func sourceKind(for container: CNContainer) -> ContactSource.Kind {
        let lower = container.name.lowercased()
        if lower.contains("icloud") { return .iCloud }
        if lower.contains("gmail") || lower.contains("google") { return .gmail }
        switch container.type {
        case .exchange: return .exchange
        case .cardDAV: return lower.contains("icloud") ? .iCloud : (lower.contains("google") ? .gmail : .cardDAV)
        case .local: return .local
        case .unassigned: return .other
        @unknown default: return .other
        }
    }

    private func probeNotesAccess(store: CNContactStore) -> Bool {
        do {
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor, CNContactNoteKey as CNKeyDescriptor])
            request.unifyResults = false; request.sortOrder = .none
            var succeeded = false
            try store.enumerateContacts(with: request) { contact, stop in _ = contact.note; succeeded = true; stop.pointee = true }
            return succeeded
        } catch { return false }
    }

    private func fetchGroupMemberships(store: CNContactStore, sources: [ContactSource]) throws -> [String: [ContactGroupSnapshot]] {
        var result: [String: [ContactGroupSnapshot]] = [:]
        for source in sources {
            let groups = try store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: source.id))
            for group in groups {
                let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
                request.unifyResults = false
                request.predicate = CNContact.predicateForContactsInGroup(withIdentifier: group.identifier)
                try store.enumerateContacts(with: request) { contact, _ in
                    result[contact.identifier, default: []].append(ContactGroupSnapshot(id: group.identifier, name: group.name, sourceIdentifier: source.id))
                }
            }
        }
        return result
    }

    private func fetchContacts(in source: ContactSource, store: CNContactStore, groupMap: [String: [ContactGroupSnapshot]], includeNote: Bool) throws -> [ContactSnapshot] {
        let request = CNContactFetchRequest(keysToFetch: Self.readKeys(includeNote: includeNote))
        request.unifyResults = false; request.sortOrder = .none
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: source.id)
        var contacts: [ContactSnapshot] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(Self.snapshot(contact, source: source, groups: groupMap[contact.identifier] ?? [], includeNote: includeNote))
        }
        return contacts
    }

    private func fetchUnifiedCount(store: CNContactStore) throws -> Int {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.unifyResults = true; request.sortOrder = .none
        var count = 0
        try store.enumerateContacts(with: request) { _, _ in count += 1 }
        return count
    }

    static func readKeys(includeNote: Bool) -> [CNKeyDescriptor] {
        var keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor, CNContactNamePrefixKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactMiddleNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor, CNContactPreviousFamilyNameKey as CNKeyDescriptor, CNContactNameSuffixKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor, CNContactPhoneticGivenNameKey as CNKeyDescriptor, CNContactPhoneticMiddleNameKey as CNKeyDescriptor, CNContactPhoneticFamilyNameKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor, CNContactDepartmentNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor, CNContactUrlAddressesKey as CNKeyDescriptor, CNContactRelationsKey as CNKeyDescriptor, CNContactDatesKey as CNKeyDescriptor, CNContactSocialProfilesKey as CNKeyDescriptor, CNContactInstantMessageAddressesKey as CNKeyDescriptor, CNContactBirthdayKey as CNKeyDescriptor, CNContactNonGregorianBirthdayKey as CNKeyDescriptor, CNContactImageDataKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor]
        if includeNote { keys.append(CNContactNoteKey as CNKeyDescriptor) }
        return keys
    }

    private static func displayLabel(_ label: String?, fallback: String) -> String {
        guard let label, !label.isEmpty else { return fallback }
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: label)
        return localized.isEmpty ? fallback : localized
    }

    static func snapshot(_ contact: CNContact, source: ContactSource, groups: [ContactGroupSnapshot], includeNote: Bool) -> ContactSnapshot {
        ContactSnapshot(
            id: contact.identifier, source: source,
            namePrefix: contact.namePrefix, givenName: contact.givenName, middleName: contact.middleName, familyName: contact.familyName,
            previousFamilyName: contact.previousFamilyName, nameSuffix: contact.nameSuffix, nickname: contact.nickname,
            phoneticGivenName: contact.phoneticGivenName, phoneticMiddleName: contact.phoneticMiddleName, phoneticFamilyName: contact.phoneticFamilyName,
            organizationName: contact.organizationName, departmentName: contact.departmentName, jobTitle: contact.jobTitle,
            phones: contact.phoneNumbers.map { LabeledString(label: displayLabel($0.label, fallback: "Telefon"), value: $0.value.stringValue) },
            emails: contact.emailAddresses.map { LabeledString(label: displayLabel($0.label, fallback: "E-posta"), value: String($0.value)) },
            postalAddresses: contact.postalAddresses.map { PostalAddressSnapshot(label: displayLabel($0.label, fallback: "Adres"), street: $0.value.street, subLocality: $0.value.subLocality, city: $0.value.city, subAdministrativeArea: $0.value.subAdministrativeArea, state: $0.value.state, postalCode: $0.value.postalCode, country: $0.value.country, isoCountryCode: $0.value.isoCountryCode) },
            urlAddresses: contact.urlAddresses.map { LabeledString(label: displayLabel($0.label, fallback: "Web"), value: String($0.value)) },
            relations: contact.contactRelations.map { LabeledString(label: displayLabel($0.label, fallback: "İlişki"), value: $0.value.name) },
            dates: contact.dates.map { LabeledDateSnapshot(label: displayLabel($0.label, fallback: "Tarih"), components: $0.value as DateComponents) },
            socialProfiles: contact.socialProfiles.map { SocialProfileSnapshot(label: displayLabel($0.label, fallback: "Sosyal"), urlString: $0.value.urlString, username: $0.value.username, userIdentifier: $0.value.userIdentifier, service: $0.value.service) },
            instantMessages: contact.instantMessageAddresses.map { InstantMessageSnapshot(label: displayLabel($0.label, fallback: "Mesajlaşma"), username: $0.value.username, service: $0.value.service) },
            birthday: contact.birthday, nonGregorianBirthday: contact.nonGregorianBirthday, imageData: contact.imageData,
            note: includeNote ? contact.note : nil, groups: groups
        )
    }
}
