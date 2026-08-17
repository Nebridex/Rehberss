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

    enum MaintenanceState: Equatable {
        case idle
        case working(String)
        case success(String)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var maintenanceState: MaintenanceState = .idle
    @Published var allowWithoutNotesEntitlement = false
    @Published private(set) var operationHistory: [ContactMaintenanceService.OperationRecord] = []

    private let scanner = ContactScanService()
    private let engine = DuplicateEngine()
    private let maintenance = ContactMaintenanceService()
    private var rawContacts: [ContactSnapshot] = []
    private var currentReport: HealthReport?

    func refreshAuthorization() async {
        operationHistory = maintenance.operationHistory()
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
                rawContacts = payload.rawContacts

                state = .scanning("Duplicate eşleşmeleri hesaplanıyor")
                let analysis = engine.analyze(payload.rawContacts)
                let groupedBySource = Dictionary(grouping: payload.rawContacts, by: \.source)
                let sourceCounts = groupedBySource.map { SourceCount(source: $0.key, count: $0.value.count) }
                    .sorted { $0.count > $1.count }

                let definite = analysis.clusters.filter { $0.confidence == .definite }
                let high = analysis.clusters.filter { $0.confidence == .high }
                let review = analysis.clusters.filter { $0.confidence == .review }
                let duplicateRecordReduction = analysis.clusters.reduce(0) { $0 + max(0, $1.contacts.count - 1) }
                let iCloudID = try? maintenance.preferredICloudContainerIdentifier(from: payload.rawContacts)

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
                    unnamedCount: analysis.unnamedCount,
                    notesAccessAvailable: payload.notesAccessAvailable,
                    preferredICloudContainerID: iCloudID
                )

                currentReport = report
                operationHistory = maintenance.operationHistory()
                maintenanceState = .idle
                state = .loaded(report)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func preview(for cluster: PersonCluster) -> MergePreview? {
        guard let id = currentReport?.preferredICloudContainerID else { return nil }
        return maintenance.mergePreview(for: cluster, preferredContainerID: id)
    }

    func createBackup() {
        guard !rawContacts.isEmpty else { return }
        Task {
            maintenanceState = .working("Tam rehber yedeği oluşturuluyor")
            do {
                let url = try await runOffMain { [rawContacts, maintenance] in
                    try maintenance.createFullBackup(from: rawContacts)
                }
                maintenanceState = .success("Yedek oluşturuldu: \(url.lastPathComponent)")
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func merge(_ cluster: PersonCluster, confirmScalarConflicts: Bool) {
        guard let containerID = currentReport?.preferredICloudContainerID else {
            maintenanceState = .failed("iCloud master rehberi bulunamadı.")
            return
        }
        let override = allowWithoutNotesEntitlement
        Task {
            maintenanceState = .working("\(cluster.title) birleştiriliyor")
            do {
                _ = try await runOffMain { [maintenance] in
                    try maintenance.merge(
                        cluster: cluster,
                        preferredContainerID: containerID,
                        allowWithoutNotesEntitlement: override,
                        confirmScalarConflicts: confirmScalarConflicts
                    )
                }
                maintenanceState = .success("Birleştirme tamamlandı ve doğrulandı.")
                scan()
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func bulkMergeDefinite() {
        guard let report = currentReport,
              let containerID = report.preferredICloudContainerID else {
            maintenanceState = .failed("iCloud master rehberi bulunamadı.")
            return
        }
        let contacts = rawContacts
        let override = allowWithoutNotesEntitlement
        Task {
            maintenanceState = .working("Toplu işlem öncesi tam yedek alınıyor")
            do {
                _ = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }
                let results = try await runOffMain { [maintenance] in
                    maintenance.safeBulkMerge(
                        clusters: report.definiteClusters,
                        preferredContainerID: containerID,
                        allowWithoutNotesEntitlement: override,
                        progress: { _, _ in }
                    )
                }
                let successes = results.filter { if case .success = $0 { true } else { false } }.count
                let failures = results.count - successes
                maintenanceState = failures == 0
                    ? .success("\(successes) güvenli duplicate birleştirildi.")
                    : .success("\(successes) birleştirildi, \(failures) kayıt güvenlik nedeniyle atlandı.")
                scan()
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func consolidateUniqueContactsToICloud() {
        guard let report = currentReport,
              let containerID = report.preferredICloudContainerID else {
            maintenanceState = .failed("iCloud master rehberi bulunamadı.")
            return
        }

        let blockedIDs = Set(
            (report.definiteClusters + report.highClusters + report.reviewClusters)
                .flatMap(\.contacts)
                .map(\.id)
        )
        let candidates = rawContacts.filter { $0.source.id != containerID && !blockedIDs.contains($0.id) }
        let contacts = rawContacts
        let override = allowWithoutNotesEntitlement

        Task {
            maintenanceState = .working("Konsolidasyon öncesi tam yedek alınıyor")
            do {
                _ = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }
                let result = try await runOffMain { [maintenance] in
                    var success = 0
                    var failed = 0
                    for snapshot in candidates {
                        do {
                            if try maintenance.migrateToICloud(
                                snapshot: snapshot,
                                preferredContainerID: containerID,
                                allowWithoutNotesEntitlement: override
                            ) != nil { success += 1 }
                        } catch {
                            failed += 1
                        }
                    }
                    return (success, failed)
                }
                maintenanceState = result.1 == 0
                    ? .success("\(result.0) benzersiz kayıt iCloud'a taşındı ve kaynakları temizlendi.")
                    : .success("\(result.0) kayıt iCloud'a taşındı; \(result.1) kayıt güvenlik nedeniyle yerinde bırakıldı.")
                scan()
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func undo(_ operation: ContactMaintenanceService.OperationRecord) {
        Task {
            maintenanceState = .working("İşlem geri alınıyor")
            do {
                try await runOffMain { [maintenance] in try maintenance.undo(operation) }
                operationHistory = maintenance.operationHistory()
                maintenanceState = .success("İşlem geri alındı.")
                scan()
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    private func runOffMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
