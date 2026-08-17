import Contacts
import Foundation

final class BulkCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class HealthViewModel: ObservableObject {
    enum State { case idle, requestingPermission, scanning(String), loaded(HealthReport), limited, denied, failed(String) }
    enum MaintenanceState: Equatable { case idle, working(String), success(String), failed(String) }

    struct BulkProgress: Equatable {
        let current: Int
        let total: Int
        let contactName: String
        var fraction: Double { total > 0 ? Double(current) / Double(total) : 0 }
    }

    @Published var state: State = .idle
    @Published var maintenanceState: MaintenanceState = .idle
    @Published var allowWithoutNotesEntitlement = false
    @Published private(set) var operationHistory: [ContactMaintenanceService.OperationRecord] = []
    @Published private(set) var bulkProgress: BulkProgress?
    @Published private(set) var isBulkMerging = false
    @Published private(set) var bulkFailureMessages: [String] = []
    @Published var selectedMasterContainerID: String? {
        didSet { if let id = selectedMasterContainerID { UserDefaults.standard.set(id, forKey: "selectedMasterContainerID") } }
    }

    private let scanner = ContactScanService()
    private let engine = DuplicateEngine()
    private let maintenance = ContactMaintenanceService()
    private let bulkCancellation = BulkCancellationToken()
    private var rawContacts: [ContactSnapshot] = []
    private var currentReport: HealthReport?

    init() { selectedMasterContainerID = UserDefaults.standard.string(forKey: "selectedMasterContainerID") }

    func refreshAuthorization() async {
        operationHistory = maintenance.operationHistory()
        switch scanner.authorizationStatus() { case .authorized: break; case .limited: state = .limited; case .denied, .restricted: state = .denied; case .notDetermined: state = .idle; @unknown default: state = .idle }
    }

    func scan() {
        guard !isBulkMerging else { return }
        Task {
            do {
                let status = scanner.authorizationStatus()
                if status == .notDetermined { state = .requestingPermission; guard try await scanner.requestAccess() else { state = .denied; return } }
                let updatedStatus = scanner.authorizationStatus()
                if updatedStatus == .limited { state = .limited; return }
                guard updatedStatus == .authorized else { state = .denied; return }
                state = .scanning("Hazırlanıyor")
                let payload = try await scanner.scan { [weak self] message in Task { @MainActor in self?.state = .scanning(message) } }
                rawContacts = payload.rawContacts
                state = .scanning("Duplicate eşleşmeleri hesaplanıyor")
                let analysis = engine.analyze(payload.rawContacts)
                let sourceCounts = Dictionary(grouping: payload.rawContacts, by: \.source).map { SourceCount(source: $0.key, count: $0.value.count) }.sorted { $0.count > $1.count }
                let definite = analysis.clusters.filter { $0.confidence == .definite }, high = analysis.clusters.filter { $0.confidence == .high }, review = analysis.clusters.filter { $0.confidence == .review }
                let reduction = analysis.clusters.reduce(0) { $0 + max(0, $1.contacts.count - 1) }
                let knownIDs = Set(payload.sources.map(\.id))
                if let selectedMasterContainerID, !knownIDs.contains(selectedMasterContainerID) { self.selectedMasterContainerID = nil }
                if selectedMasterContainerID == nil, let defaultID = payload.defaultContainerIdentifier, knownIDs.contains(defaultID) { selectedMasterContainerID = defaultID }
                let detectedICloudID = try? maintenance.preferredICloudContainerIdentifier(from: payload.rawContacts)
                let report = HealthReport(generatedAt: Date(), rawContactCount: payload.rawContacts.count, unifiedContactCount: payload.unifiedCount, estimatedUniquePeople: max(0, payload.rawContacts.count - reduction), sourceCounts: sourceCounts, definiteClusters: definite, highClusters: high, reviewClusters: review, samePhoneGroupCount: analysis.samePhoneGroups, sameEmailGroupCount: analysis.sameEmailGroups, unnamedCount: analysis.unnamedCount, notesAccessAvailable: payload.notesAccessAvailable, preferredICloudContainerID: detectedICloudID, defaultContainerID: payload.defaultContainerIdentifier)
                currentReport = report
                operationHistory = maintenance.operationHistory()
                state = .loaded(report)
            } catch { state = .failed(error.localizedDescription) }
        }
    }

    func clearMaintenanceState() { maintenanceState = .idle }
    func selectMasterContainer(_ id: String) { selectedMasterContainerID = id }
    func preview(for cluster: PersonCluster) -> MergePreview? { guard let id = selectedMasterContainerID else { return nil }; return maintenance.mergePreview(for: cluster, preferredContainerID: id) }
    func safeBulkEligibleCount() -> Int {
        guard let report = currentReport, let id = selectedMasterContainerID else { return 0 }
        return maintenance.eligibleDefiniteClusters(report.definiteClusters, preferredContainerID: id).count
    }

    func createBackup() { guard !rawContacts.isEmpty, !isBulkMerging else { return }; let contacts = rawContacts; Task { maintenanceState = .working("Tam rehber yedeği oluşturuluyor"); do { let url: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }; maintenanceState = .success("Yedek oluşturuldu: \(url.lastPathComponent)") } catch { maintenanceState = .failed(error.localizedDescription) } } }

    func merge(_ cluster: PersonCluster, confirmScalarConflicts: Bool) {
        guard !isBulkMerging else { return }
        guard let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let override = allowWithoutNotesEntitlement
        Task {
            maintenanceState = .working("\(cluster.title) birleştiriliyor")
            do {
                let _: Void = try await runOffMain { [maintenance] in _ = try maintenance.merge(cluster: cluster, preferredContainerID: containerID, allowWithoutNotesEntitlement: override, confirmScalarConflicts: confirmScalarConflicts) }
                operationHistory = maintenance.operationHistory()
                maintenanceState = .success("Birleştirme tamamlandı ve doğrulandı. Rehberi kontrol ettikten sonra Yeniden Tara ile listeyi güncelleyebilirsin.")
            } catch { maintenanceState = .failed(error.localizedDescription) }
        }
    }

    func cancelBulkMerge() {
        guard isBulkMerging else { return }
        bulkCancellation.cancel()
        maintenanceState = .working("İptal istendi. Devam eden kişi güvenli şekilde tamamlandıktan sonra duracak.")
    }

    func bulkMergeDefinite() {
        guard !isBulkMerging else { return }
        guard let report = currentReport, let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let contacts = rawContacts
        let override = allowWithoutNotesEntitlement
        let clusters = report.definiteClusters
        let token = bulkCancellation
        token.reset()
        bulkFailureMessages = []
        isBulkMerging = true
        bulkProgress = nil

        Task {
            maintenanceState = .working("Toplu işlem öncesi tam rehber yedeği alınıyor")
            do {
                let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }
                let summary: ContactMaintenanceService.BulkMergeSummary = await Task.detached(priority: .userInitiated) { [maintenance] in
                    maintenance.safeBulkMerge(
                        clusters: clusters,
                        preferredContainerID: containerID,
                        allowWithoutNotesEntitlement: override,
                        shouldCancel: { token.isCancelled() },
                        progress: { current, total, name in
                            Task { @MainActor [weak self] in
                                self?.bulkProgress = BulkProgress(current: current, total: total, contactName: name)
                                self?.maintenanceState = .working("\(current)/\(total) — \(name)")
                            }
                        }
                    )
                }.value

                operationHistory = maintenance.operationHistory()
                bulkFailureMessages = summary.failureMessages
                isBulkMerging = false
                bulkProgress = nil

                if summary.cancelled {
                    maintenanceState = .success("Toplu işlem durduruldu. \(summary.successCount) kişi birleştirildi, \(summary.failedCount) hata oldu. Tamamlanan işlemler Undo ile geri alınabilir.")
                } else if summary.eligibleCount > 0 && summary.successCount == 0 {
                    let firstReason = summary.failureMessages.first ?? "Contacts işlemi kaynak kayıtları kabul etmedi."
                    maintenanceState = .failed("Toplu merge uygulanmadı: 0/\(summary.eligibleCount) başarılı. İlk hata: \(firstReason)")
                } else {
                    maintenanceState = .success("Toplu işlem tamamlandı: \(summary.successCount)/\(summary.eligibleCount) güvenli grup birleştirildi, \(summary.failedCount) grup atlandı.")
                }
            } catch {
                isBulkMerging = false
                bulkProgress = nil
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func consolidateUniqueContactsToICloud() {
        guard !isBulkMerging else { return }
        guard let report = currentReport, let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let blockedIDs = Set((report.definiteClusters + report.highClusters + report.reviewClusters).flatMap(\.contacts).map(\.id)); let candidates = rawContacts.filter { $0.source.id != containerID && !blockedIDs.contains($0.id) }; let contacts = rawContacts, override = allowWithoutNotesEntitlement
        Task { maintenanceState = .working("Konsolidasyon öncesi tam yedek alınıyor"); do { let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }; let counts: [Int] = try await runOffMain { [maintenance] in var success=0, failed=0; for snapshot in candidates { do { if try maintenance.migrateToICloud(snapshot: snapshot, preferredContainerID: containerID, allowWithoutNotesEntitlement: override) != nil { success += 1 } } catch { failed += 1 } }; return [success,failed] }; maintenanceState = .success("\(counts[0]) kayıt ana rehbere taşındı; \(counts[1]) kayıt atlandı."); scan() } catch { maintenanceState = .failed(error.localizedDescription) } }
    }

    func undo(_ operation: ContactMaintenanceService.OperationRecord) {
        guard !isBulkMerging else { return }
        Task { maintenanceState = .working("İşlem geri alınıyor"); do { let _: Void = try await runOffMain { [maintenance] in try maintenance.undo(operation) }; operationHistory = maintenance.operationHistory(); maintenanceState = .success("İşlem geri alındı."); scan() } catch { maintenanceState = .failed(error.localizedDescription) } }
    }

    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached(priority: .userInitiated, operation: work).value }
}
