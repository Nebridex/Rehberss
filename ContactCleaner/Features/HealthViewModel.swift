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
        let contacts = rawContacts
        Task {
            maintenanceState = .working("Tam rehber yedeği oluşturuluyor")
            do {
                let url: URL = try await runOffMain { [maintenance] in
                    try maintenance.createFullBackup(from: contacts)
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
                let _: Void = try await runOffMain { [maintenance] in
                    _ = try maintenance.merge(
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
        let clusters = report.definiteClusters
        Task {
            maintenanceState = .working("Toplu işlem öncesi tam yedek alınıyor")
            do {
                let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }
                let counts: [Int] = try await runOffMain { [maintenance] in
                    let results = maintenance.safeBulkMerge(
                        clusters: clusters,
                        preferredContainerID: containerID,
                        allowWithoutNotesEntitlement: override,
                        progress: { _, _ in }
                    )
                    let success = results.reduce(0) { partial, result in
                        if case .success = result { return partial + 1 }
                        return partial
                    }
                    return [success, results.count - success]
                }
                let successes = counts.first ?? 0
                let failures = counts.dropFirst().first ?? 0
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
                let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }
                let counts: [Int] = try await runOffMain { [maintenance] in
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
                    return [success, failed]
                }
                let success = counts.first ?? 0
                let failed = counts.dropFirst().first ?? 0
                maintenanceState = failed == 0
                    ? .success("\(success) benzersiz kayıt iCloud'a taşındı ve kaynakları temizlendi.")
                    : .success("\(success) kayıt iCloud'a taşındı; \(failed) kayıt güvenlik nedeniyle yerinde bırakıldı.")
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
                let _: Void = try await runOffMain { [maintenance] in
                    try maintenance.undo(operation)
                }
                operationHistory = maintenance.operationHistory()
                maintenanceState = .success("İşlem geri alındı.")
                scan()
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
