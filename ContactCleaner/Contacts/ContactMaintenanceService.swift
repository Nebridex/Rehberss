import Contacts
import Foundation

final class ContactMaintenanceService: @unchecked Sendable {
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

    enum OperationKind: String, Codable, Sendable {
        case merge
        case migration
    }

    struct OperationRecord: Codable, Identifiable, Sendable {
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

    let store: CNContactStore
    let encoder: JSONEncoder
    let decoder: JSONDecoder

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

    func preferredICloudContainerIdentifier(from contacts: [ContactSnapshot]) throws -> String {
        let grouped = Dictionary(grouping: contacts.filter { $0.source.kind == .iCloud }, by: { $0.source.id })
        if let best = grouped.max(by: { $0.value.count < $1.value.count })?.key { return best }

        let containers = try store.containers(matching: nil)
        if let container = containers.first(where: { $0.name.lowercased().contains("icloud") }) {
            return container.identifier
        }
        throw MaintenanceError.iCloudContainerNotFound
    }
}

struct MergePreview: Identifiable, Hashable, Sendable {
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
