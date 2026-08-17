import Contacts
import Foundation

@MainActor
final class HealthViewModel: ObservableObject {
    enum State { case idle, requestingPermission, scanning(String), loaded(HealthReport), limited, denied, failed(String) }
    enum MaintenanceState: Equatable { case idle, working(String), success(String), failed(String) }

    @Published var state: State = .idle
    @Published var maintenanceState: MaintenanceState = .idle
    @Published var allowWithoutNotesEntitlement = false
    @Published private(set) var operationHistory: [ContactMaintenanceService.OperationRecord] = []
    @Published var selectedMasterContainerID: String? {
        didSet { if let id = selectedMasterContainerID { UserDefaults.standard.set(id, forKey: "selectedMasterContainerID") } }
    }

    private let scanner = ContactScanService()
    private let engine = DuplicateEngine()
    private let maintenance = ContactMaintenanceService()
    private var rawContacts: [ContactSnapshot] = []
    private var currentReport: HealthReport?

    init() { selectedMasterContainerID = UserDefaults.standard.string(forKey: "selectedMasterContainerID") }

    func refreshAuthorization() async {
        operationHistory = maintenance.operationHistory()
        switch scanner.authorizationStatus() { case .authorized: break; case .limited: state = .limited; case .denied, .restricted: state = .denied; case .notDetermined: state = .idle; @unknown default: state = .idle }
    }

    func scan() {
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

    func createBackup() { guard !rawContacts.isEmpty else { return }; let contacts = rawContacts; Task { maintenanceState = .working("Tam rehber yedeği oluşturuluyor"); do { let url: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }; maintenanceState = .success("Yedek oluşturuldu: \(url.lastPathComponent)") } catch { maintenanceState = .failed(error.localizedDescription) } } }

    func merge(_ cluster: PersonCluster, confirmScalarConflicts: Bool) {
        guard let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let override = allowWithoutNotesEntitlement
        Task {
            maintenanceState = .working("\(cluster.title) birleştiriliyor")
            do {
                let _: Void = try await runOffMain { [maintenance] in
                    _ = try maintenance.merge(cluster: cluster, preferredContainerID: containerID, allowWithoutNotesEntitlement: override, confirmScalarConflicts: confirmScalarConflicts)
                }
                operationHistory = maintenance.operationHistory()
                maintenanceState = .success("Birleştirme tamamlandı ve doğrulandı. Rehberi kontrol ettikten sonra Yeniden Tara ile listeyi güncelleyebilirsin.")
            } catch {
                maintenanceState = .failed(error.localizedDescription)
            }
        }
    }

    func bulkMergeDefinite() {
        guard let report = currentReport, let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let contacts = rawContacts, override = allowWithoutNotesEntitlement, clusters = report.definiteClusters
        Task { maintenanceState = .working("Toplu işlem öncesi tam yedek alınıyor"); do { let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }; let counts: [Int] = try await runOffMain { [maintenance] in let results = maintenance.safeBulkMerge(clusters: clusters, preferredContainerID: containerID, allowWithoutNotesEntitlement: override, progress: { _, _ in }); let success = results.reduce(0) { p, r in if case .success = r { return p + 1 }; return p }; return [success, results.count-success] }; maintenanceState = .success("\(counts[0]) birleştirildi, \(counts[1]) güvenlik nedeniyle atlandı."); scan() } catch { maintenanceState = .failed(error.localizedDescription) } }
    }

    func consolidateUniqueContactsToICloud() {
        guard let report = currentReport, let containerID = selectedMasterContainerID else { maintenanceState = .failed("Önce Ana Rehber seç."); return }
        let blockedIDs = Set((report.definiteClusters + report.highClusters + report.reviewClusters).flatMap(\.contacts).map(\.id)); let candidates = rawContacts.filter { $0.source.id != containerID && !blockedIDs.contains($0.id) }; let contacts = rawContacts, override = allowWithoutNotesEntitlement
        Task { maintenanceState = .working("Konsolidasyon öncesi tam yedek alınıyor"); do { let _: URL = try await runOffMain { [maintenance] in try maintenance.createFullBackup(from: contacts) }; let counts: [Int] = try await runOffMain { [maintenance] in var success=0, failed=0; for snapshot in candidates { do { if try maintenance.migrateToICloud(snapshot: snapshot, preferredContainerID: containerID, allowWithoutNotesEntitlement: override) != nil { success += 1 } } catch { failed += 1 } }; return [success,failed] }; maintenanceState = .success("\(counts[0]) kayıt ana rehbere taşındı; \(counts[1]) kayıt atlandı."); scan() } catch { maintenanceState = .failed(error.localizedDescription) } }
    }

    func undo(_ operation: ContactMaintenanceService.OperationRecord) { Task { maintenanceState = .working("İşlem geri alınıyor"); do { let _: Void = try await runOffMain { [maintenance] in try maintenance.undo(operation) }; operationHistory = maintenance.operationHistory(); maintenanceState = .success("İşlem geri alındı."); scan() } catch { maintenanceState = .failed(error.localizedDescription) } } }
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T { try await Task.detached(priority: .userInitiated, operation: work).value }
}
