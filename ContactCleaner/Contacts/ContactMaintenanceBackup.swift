import Contacts
import Foundation

extension ContactMaintenanceService {
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

    func ensureBackupDirectory() throws {
        try FileManager.default.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
    }

    func appendOperation(_ record: OperationRecord) throws {
        try ensureBackupDirectory()
        var history = operationHistory()
        history.append(record)
        try encoder.encode(history).write(to: journalURL, options: .atomic)
    }

    func removeOperation(_ id: UUID) throws {
        var history = operationHistory()
        history.removeAll { $0.id == id }
        try encoder.encode(history).write(to: journalURL, options: .atomic)
    }
}
