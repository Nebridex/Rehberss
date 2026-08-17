import SwiftUI

struct HealthDashboardView: View {
    let report: HealthReport
    @ObservedObject var viewModel: HealthViewModel
    @State private var showBulkConfirmation = false
    @State private var showConsolidationConfirmation = false
    @State private var showNotesOverrideConfirmation = false

    var body: some View {
        List {
            Section("Özet") { MetricRow(title: "Fiziksel kayıt", value: report.rawContactCount); MetricRow(title: "iOS unified kişi", value: report.unifiedContactCount); MetricRow(title: "Tahmini benzersiz kişi", value: report.estimatedUniquePeople) }

            Section("Kaynaklar") {
                ForEach(report.sourceCounts) { item in HStack { VStack(alignment: .leading) { Text(item.source.name); Text(sourceDescription(item.source)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(item.count.formatted()).monospacedDigit() } }
            }

            Section("Ana Rehber") {
                Picker("Birleştirme hedefi", selection: Binding(get: { viewModel.selectedMasterContainerID ?? "" }, set: { if !$0.isEmpty { viewModel.selectMasterContainer($0) } })) {
                    Text("Seçilmedi").tag("")
                    ForEach(report.sourceCounts) { item in
                        Text(masterLabel(item)).tag(item.source.id)
                    }
                }
                if let id = viewModel.selectedMasterContainerID, let selected = report.sourceCounts.first(where: { $0.source.id == id }) {
                    Label("Tüm merge ve taşıma işlemleri \"\(selected.source.name)\" kaynağında master kayıt oluşturacak.", systemImage: "checkmark.shield")
                        .font(.footnote)
                } else {
                    Label("Merge kapalı. Önce hangi rehberin ana kaynak olacağını seç.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Varsayılan iOS rehberi otomatik önerilir; isimden iCloud tahmini yapılmaz. Seçimi değiştirebilirsin.").font(.footnote).foregroundStyle(.secondary)
            }

            Section("Güvenlik") {
                Label(report.notesAccessAvailable ? "Contacts Notes erişimi hazır" : "Contacts Notes erişimi yok", systemImage: report.notesAccessAvailable ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                if !report.notesAccessAvailable {
                    Toggle("Notes koruması olmadan devam et", isOn: Binding(get: { viewModel.allowWithoutNotesEntitlement }, set: { value in if value { showNotesOverrideConfirmation = true } else { viewModel.allowWithoutNotesEntitlement = false } }))
                        .confirmationDialog("Notes alanı okunamayabilir", isPresented: $showNotesOverrideConfirmation, titleVisibility: .visible) { Button("Riski kabul et", role: .destructive) { viewModel.allowWithoutNotesEntitlement = true }; Button("Vazgeç", role: .cancel) { viewModel.allowWithoutNotesEntitlement = false } } message: { Text("Apple Notes entitlement yokken contact notlarının varlığını doğrulayamıyoruz.") }
                }
                Button { viewModel.createBackup() } label: { Label("Tam Rehber Yedeği Oluştur", systemImage: "externaldrive.badge.timemachine") }
            }

            Section("Duplicate Analizi") {
                NavigationLink { DuplicateListView(title: "Kesin duplicate", clusters: report.definiteClusters, viewModel: viewModel) } label: { MetricRow(title: "Kesin duplicate", value: report.definiteClusters.count) }
                NavigationLink { DuplicateListView(title: "Yüksek olasılıklı", clusters: report.highClusters, viewModel: viewModel) } label: { MetricRow(title: "Yüksek olasılıklı", value: report.highClusters.count) }
                NavigationLink { DuplicateListView(title: "İncelenmeli", clusters: report.reviewClusters, viewModel: viewModel) } label: { MetricRow(title: "İncelenmeli", value: report.reviewClusters.count) }
                MetricRow(title: "Aynı numara grubu", value: report.samePhoneGroupCount); MetricRow(title: "Aynı e-posta grubu", value: report.sameEmailGroupCount); MetricRow(title: "İsimsiz kayıt", value: report.unnamedCount)
            }

            Section("Toplu İşlemler") {
                Button { showBulkConfirmation = true } label: { Label("Güvenli Kesin Duplicate'leri Birleştir", systemImage: "person.2.badge.checkmark") }
                    .disabled(report.definiteClusters.isEmpty || viewModel.selectedMasterContainerID == nil || (!report.notesAccessAvailable && !viewModel.allowWithoutNotesEntitlement))
                    .confirmationDialog("Kesin duplicate'ler toplu birleştirilsin mi?", isPresented: $showBulkConfirmation, titleVisibility: .visible) { Button("Yedekle ve Birleştir", role: .destructive) { viewModel.bulkMergeDefinite() }; Button("Vazgeç", role: .cancel) {} } message: { Text("Yalnızca kesin ve güvenli kümeler işlenir. Önce tüm rehberin yedeği alınır.") }
                Button { showConsolidationConfirmation = true } label: { Label("Benzersiz Kayıtları Ana Rehbere Taşı", systemImage: "icloud.and.arrow.up") }
                    .disabled(viewModel.selectedMasterContainerID == nil || (!report.notesAccessAvailable && !viewModel.allowWithoutNotesEntitlement))
                    .confirmationDialog("Rehber seçilen ana kaynakta konsolide edilsin mi?", isPresented: $showConsolidationConfirmation, titleVisibility: .visible) { Button("Yedekle ve Taşı", role: .destructive) { viewModel.consolidateUniqueContactsToICloud() }; Button("Vazgeç", role: .cancel) {} } message: { Text("Duplicate kümeleri atlanır. Benzersiz kayıtlar seçtiğin ana rehbere kopyalanır, doğrulanır ve ancak sonra eski kaynaktan silinir.") }
            }

            if !viewModel.operationHistory.isEmpty { Section("İşlem Geçmişi / Undo") { ForEach(viewModel.operationHistory.prefix(20)) { operation in HStack { VStack(alignment: .leading, spacing: 3) { Text(operation.kind == .merge ? "Merge" : "Ana rehbere taşıma").font(.subheadline.weight(.semibold)); Text(operation.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Geri Al") { viewModel.undo(operation) }.buttonStyle(.bordered) } } } }
            Section { Button("Yeniden Tara", action: viewModel.scan) } footer: { Text("Kaynak kayıt yalnızca master kayıt kaydedilip tekrar okunarak doğrulandıktan sonra silinir.") }
        }
    }

    private func sourceDescription(_ source: ContactSource) -> String { switch source.kind { case .iCloud: "iCloud"; case .gmail: "Google/Gmail"; case .exchange: "Exchange"; case .cardDAV: "CardDAV"; case .local: "Bu iPhone"; case .other: "Diğer" } }
    private func masterLabel(_ item: SourceCount) -> String { var text = "\(item.source.name) — \(sourceDescription(item.source)) — \(item.count) kayıt"; if item.source.id == report.defaultContainerID { text += " (iOS varsayılan)" }; return text }
}

private struct MetricRow: View { let title: String; let value: Int; var body: some View { HStack { Text(title); Spacer(); Text(value.formatted()).fontWeight(.semibold).monospacedDigit() } } }
