import Contacts
import Foundation

extension ContactMaintenanceService {
    func fetchRawContacts(ids: [String], keys: [CNKeyDescriptor]) throws -> [CNContact] {
        guard !ids.isEmpty else { return [] }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = false
        request.sortOrder = .none
        request.predicate = CNContact.predicateForContacts(withIdentifiers: ids)
        var found: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in found.append(contact) }
        return found
    }

    func snapshotsFromFreshContacts(
        _ contacts: [CNContact],
        previous: [ContactSnapshot],
        includeNote: Bool
    ) throws -> [ContactSnapshot] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return try contacts.map { contact in
            guard let prior = previousByID[contact.identifier] else {
                throw MaintenanceError.contactNotFound(contact.identifier)
            }
            return ContactScanService.snapshot(contact, source: prior.source, groups: prior.groups, includeNote: includeNote)
        }
    }

    func containerIdentifier(for contactID: String) -> String? {
        try? store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: contactID)).first?.identifier
    }

    func applyMergedValues(from contacts: [CNContact], to target: CNMutableContact, includeNote: Bool) {
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
        target.socialProfiles = unionLabeled(contacts.flatMap(\.socialProfiles)) { socialKey($0.value) }
        target.instantMessageAddresses = unionLabeled(contacts.flatMap(\.instantMessageAddresses)) { instantMessageKey($0.value) }
        target.dates = unionLabeled(contacts.flatMap(\.dates)) { dateKey($0.value as DateComponents) }

        if target.birthday == nil { target.birthday = contacts.compactMap(\.birthday).first }
        if target.nonGregorianBirthday == nil { target.nonGregorianBirthday = contacts.compactMap(\.nonGregorianBirthday).first }
        if target.imageData == nil, let image = contacts.compactMap(\.imageData).max(by: { $0.count < $1.count }) { target.imageData = image }
        if includeNote {
            let notes = nonEmptyUnique(contacts.map(\.note))
            if !notes.isEmpty { target.note = notes.joined(separator: "\n\n---\n\n") }
        }
    }

    func copy(contact: CNContact, to target: CNMutableContact, includeNote: Bool) {
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

    func apply(snapshot: ContactSnapshot, to target: CNMutableContact, includeNote: Bool) {
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

    static func mergeKeys(includeNote: Bool) -> [CNKeyDescriptor] {
        ContactScanService.readKeys(includeNote: includeNote)
    }

    func preferredString(_ preferred: String, values: [String]) -> String {
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return preferred }
        return nonEmptyUnique(values).max(by: { $0.count < $1.count }) ?? ""
    }

    func combinedDistinct(_ values: [String], preferred: String) -> String {
        var ordered: [String] = []
        if !preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ordered.append(preferred) }
        for value in nonEmptyUnique(values) where !ordered.contains(value) { ordered.append(value) }
        return ordered.joined(separator: " / ")
    }

    func bestName(_ contacts: [ContactSnapshot]) -> String {
        contacts.map(\.displayName).filter { $0 != "İsimsiz Kayıt" }.max(by: { $0.count < $1.count }) ?? "İsimsiz Kayıt"
    }

    func nonEmptyUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return seen.insert(trimmed.lowercased()).inserted
        }
    }

    func unique<T>(_ values: [T], key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return values.filter {
            let k = key($0)
            guard !k.isEmpty else { return false }
            return seen.insert(k).inserted
        }
    }

    func unionLabeled<T>(_ values: [CNLabeledValue<T>], key: (CNLabeledValue<T>) -> String) -> [CNLabeledValue<T>] {
        unique(values, key: key)
    }

    func uniqueDates(_ values: [DateComponents]) -> [DateComponents] { unique(values, key: dateKey) }
    func dateKey(_ value: DateComponents) -> String { "\(value.era ?? -1)|\(value.year ?? -1)|\(value.month ?? -1)|\(value.day ?? -1)" }

    func postalKey(_ value: CNPostalAddress) -> String {
        [value.street, value.subLocality, value.city, value.subAdministrativeArea, value.state, value.postalCode, value.country, value.isoCountryCode]
            .joined(separator: "|").lowercased()
    }

    func socialKey(_ value: CNSocialProfile) -> String {
        "\(value.service)|\(value.username)|\(value.userIdentifier)|\(value.urlString)".lowercased()
    }

    func instantMessageKey(_ value: CNInstantMessageAddress) -> String {
        "\(value.service)|\(value.username)".lowercased()
    }
}
