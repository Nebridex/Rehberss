import Contacts
import Foundation

@MainActor
final class HealthViewModel: ObservableObject {
    enum State {
        case idle
        case requestingPermission
        case scanning(String)
        case loaded(HealthReport)
        case limited
        case denied
        case failed(String)
    }

    @Published var state: State = .idle

    private let scanner = ContactScanService()
    private let engine = DuplicateEngine()

    func refreshAuthorization() async {
        switch scanner.authorizationStatus() {
        case .authorized:
            break
        case .limited:
            state = .limited
        case .denied, .restricted:
            state = .denied
        case .notDetermined:
            state = .idle
        @unknown default:
            state = .idle
        }
    }

    func scan() {
        Task {
            do {
                let status = scanner.authorizationStatus()
                if status == .notDetermined {
                    state = .requestingPermission
                    let granted = try await scanner.requestAccess()
                    guard granted else {
                        state = .denied
                        return
                    }
                }

                let updatedStatus = scanner.authorizationStatus()
                if updatedStatus == .limited {
                    state = .limited
                    return
                }
                guard updatedStatus == .authorized else {
                    state = .denied
                    return
                }

                state = .scanning("Hazırlanıyor")
                let payload = try await scanner.scan { [weak self] message in
                    Task { @MainActor in self?.state = .scanning(message) }
                }

                state = .scanning("Duplicate eşleşmeleri hesaplanıyor")
                let analysis = engine.analyze(payload.rawContacts)

                let groupedBySource = Dictionary(grouping: payload.rawContacts, by: \.source)
                let sourceCounts = groupedBySource.map { SourceCount(source: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }

                let definite = analysis.clusters.filter { $0.confidence == .definite }
                let high = analysis.clusters.filter { $0.confidence == .high }
                let review = analysis.clusters.filter { $0.confidence == .review }

                let duplicateRecordReduction = analysis.clusters.reduce(0) { partial, cluster in
                    partial + max(0, cluster.contacts.count - 1)
                }

                let report = HealthReport(
                    generatedAt: Date(),
                    rawContactCount: payload.rawContacts.count,
                    unifiedContactCount: payload.unifiedCount,
                    estimatedUniquePeople: max(0, payload.rawContacts.count - duplicateRecordReduction),
                    sourceCounts: sourceCounts,
                    definiteClusters: definite,
                    highClusters: high,
                    reviewClusters: review,
                    samePhoneGroupCount: analysis.samePhoneGroups,
                    sameEmailGroupCount: analysis.sameEmailGroups,
                    unnamedCount: analysis.unnamedCount
                )

                state = .loaded(report)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
