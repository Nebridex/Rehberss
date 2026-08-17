import Contacts
import Foundation

final class ContactScanService {
    private let store = CNContactStore()

    struct ScanPayload {
        let rawContacts: [ContactSnapshot]
        let unifiedCount: Int
    }

    func authorizationStatus() -> CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func scan(progress: @escaping (String) -> Void) async throws -> ScanPayload {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [store] in
                do {
                    progress("Kaynak hesaplar bulunuyor")
                    let sources = try self.fetchSources(store: store)

                    progress("Fiziksel kişi kayıtları okunuyor")
                    var raw: [ContactSnapshot] = []
                    for source in sources {
                        raw.append(contentsOf: try self.fetchContacts(in: source, store: store, unifyResults: false))
                    }

                    progress("iOS unified kişi görünümü sayılıyor")
                    let unifiedCount = try self.fetchUnifiedCount(store: store)

                    continuation.resume(returning: ScanPayload(rawContacts: raw, unifiedCount: unifiedCount))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchSources(store: CNContactStore) throws -> [ContactSource] {
        let containers = try store.containers(matching: nil)
        return containers.map { container in
            ContactSource(
                id: container.identifier,
                name: container.name.isEmpty ? "Bilinmeyen Kaynak" : container.name,
                kind: sourceKind(for: container)
            )
        }
    }

    private func sourceKind(for container: CNContainer) -> ContactSource.Kind {
        let lower = container.name.lowercased()
        if lower.contains("icloud") { return .iCloud }
        if lower.contains("gmail") || lower.contains("google") { return .gmail }

        switch container.type {
        case .exchange:
            return .exchange
        case .cardDAV:
            return lower.contains("icloud") ? .iCloud : (lower.contains("google") ? .gmail : .cardDAV)
        case .local:
            return .local
        case .unassigned:
            return .other
        @unknown default:
            return .other
        }
    }

    private func fetchContacts(in source: ContactSource, store: CNContactStore, unifyResults: Bool) throws -> [ContactSnapshot] {
        let request = CNContactFetchRequest(keysToFetch: Self.readOnlyKeys)
        request.unifyResults = unifyResults
        request.sortOrder = .none
        request.predicate = CNContact.predicateForContactsInContainer(withIdentifier: source.id)

        var contacts: [ContactSnapshot] = []
        try store.enumerateContacts(with: request) { contact, _ in
            contacts.append(Self.snapshot(contact, source: source))
        }
        return contacts
    }

    private func fetchUnifiedCount(store: CNContactStore) throws -> Int {
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        request.unifyResults = true
        request.sortOrder = .none
        var count = 0
        try store.enumerateContacts(with: request) { _, _ in count += 1 }
        return count
    }

    private static let readOnlyKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor
        // CNContactNoteKey intentionally excluded until the Apple Notes entitlement is enabled.
    ]

    private static func snapshot(_ contact: CNContact, source: ContactSource) -> ContactSnapshot {
        ContactSnapshot(
            id: contact.identifier,
            source: source,
            givenName: contact.givenName,
            middleName: contact.middleName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organizationName: contact.organizationName,
            departmentName: contact.departmentName,
            jobTitle: contact.jobTitle,
            phones: contact.phoneNumbers.map {
                LabeledString(label: CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "Telefon"), value: $0.value.stringValue)
            },
            emails: contact.emailAddresses.map {
                LabeledString(label: CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? "E-posta"), value: String($0.value))
            },
            birthday: contact.birthday,
            hasImage: contact.imageDataAvailable
        )
    }
}
