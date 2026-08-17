import Foundation

struct ContactSource: Identifiable, Hashable, Codable {
    enum Kind: String, Codable, CaseIterable {
        case iCloud
        case gmail
        case exchange
        case cardDAV
        case local
        case other
    }

    let id: String
    let name: String
    let kind: Kind
}

struct LabeledString: Hashable, Codable, Identifiable {
    var id: String { "\(label)|\(value)" }
    let label: String
    let value: String
}

struct ContactSnapshot: Identifiable, Hashable, Codable {
    let id: String
    let source: ContactSource

    let givenName: String
    let middleName: String
    let familyName: String
    let nickname: String
    let organizationName: String
    let departmentName: String
    let jobTitle: String

    let phones: [LabeledString]
    let emails: [LabeledString]

    let birthday: DateComponents?
    let hasImage: Bool

    var displayName: String {
        let parts = [givenName, middleName, familyName].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        if !organizationName.isEmpty { return organizationName }
        return "İsimsiz Kayıt"
    }
}

enum DuplicateConfidence: String, Codable, CaseIterable {
    case definite = "Kesin duplicate"
    case high = "Yüksek olasılıklı"
    case review = "İncelenmeli"

    var rank: Int {
        switch self {
        case .definite: return 3
        case .high: return 2
        case .review: return 1
        }
    }
}

enum MatchEvidenceKind: String, Codable {
    case exactPhone
    case exactEmail
    case exactName
    case normalizedName
    case similarName
    case sameCompany
    case sameBirthday
    case birthdayConflict
}

struct MatchEvidence: Hashable, Codable, Identifiable {
    var id: String { "\(kind.rawValue)|\(detail)" }
    let kind: MatchEvidenceKind
    let detail: String
}

struct DuplicatePair: Hashable, Codable {
    let leftID: String
    let rightID: String
    let confidence: DuplicateConfidence
    let score: Int
    let evidence: [MatchEvidence]
    let hasHardConflict: Bool
}

struct PersonCluster: Identifiable, Hashable, Codable {
    let id: String
    let contacts: [ContactSnapshot]
    let confidence: DuplicateConfidence
    let evidence: [MatchEvidence]
    let hasHardConflict: Bool

    var title: String {
        contacts.first?.displayName ?? "Eşleşme"
    }
}

struct SourceCount: Identifiable, Hashable, Codable {
    var id: String { "\(source.id)-\(count)" }
    let source: ContactSource
    let count: Int
}

struct HealthReport: Codable {
    let generatedAt: Date
    let rawContactCount: Int
    let unifiedContactCount: Int
    let estimatedUniquePeople: Int
    let sourceCounts: [SourceCount]
    let definiteClusters: [PersonCluster]
    let highClusters: [PersonCluster]
    let reviewClusters: [PersonCluster]
    let samePhoneGroupCount: Int
    let sameEmailGroupCount: Int
    let unnamedCount: Int
}
