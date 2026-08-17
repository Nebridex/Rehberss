import SwiftUI

struct HealthDashboardView: View {
    let report: HealthReport
    @ObservedObject var viewModel: HealthViewModel

    @State private var showBulkConfirmation = false
    @State private var showConsolidationConfirmation = false
    @State private var showNotesOverrideConfirmation = false

    var body: some View {
        List {
            Section("Özet") {
                MetricRow(title: "Fiziksel kayıt", value: report.rawContactCount)
                MetricRow(title: "iOS unified kişi", value: report.unifiedContactCount)
                MetricRow(title: "Tahmini benzersiz kişi", value: report.estimatedUniquePeople)
            }

            Section("Kaynaklar") {
                ForEach(report.sourceCounts) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.source.name)
                            Text(item.source.kind.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(item.count.formatted())
                            .monospacedDigit()
                    }
                }
            }

            Section("Güvenlik") {
                Label(
                    report.notesAccessAvailable ? "Contacts Notes erişimi hazır" : "Contacts Notes erişimi yok",
                    systemImage: report.notesAccessAvailable ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
                )

                if !report.notesAccessAvailable {
                    Toggle("Notes koruması olmadan devam et", isOn: Binding(
                        get: { viewModel.allowWithoutNotesEntitlement },
                        set: { value in
                            if value { showNotesOverrideConfirmation = true }
                            else { viewModel.allowWithoutNotesEntitlement = false }
                        }
                    ))
                    .confirmationDialog(
                        "Notes alanı okunamayabilir",
                        isPresented: $showNotesOverrideConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Riski kabul et", role: .destructive) {
                            viewModel.allowWithoutNotesEntitlement = true
                        }
                        Button("Vazgeç", role: .cancel) {
                            viewModel.allowWithoutNotesEntitlement = false
                        }
                    } message: {
                        Text("Apple Notes entitlement yokken contact notlarının varlığını doğrulayamıyoruz. Bu seçenek yalnızca kendi cihazındaki rehberi temizlemek için bilinçli olarak açılmalı.")
                    }
                }

                Button {
                    viewModel.createBackup()
                } label: {
                    Label("Tam Rehber Yedeği Oluştur", systemImage: "externaldrive.badge.timemachine")
                }
            }

            Section("Duplicate Analizi") {
                NavigationLink {
                    DuplicateListView(title: "Kesin duplicate", clusters: report.definiteClusters, viewModel: viewModel)
                } label: {
                    MetricRow(title: "Kesin duplicate", value: report.definiteClusters.count)
                }

                NavigationLink {
                    DuplicateListView(title: "Yüksek olasılıklı", clusters: report.highClusters, viewModel: viewModel)
                } label: {
                    MetricRow(title: "Yüksek olasılıklı", value: report.highClusters.count)
                }

                NavigationLink {
                    DuplicateListView(title: "İncelenmeli", clusters: report.reviewClusters, viewModel: viewModel)
                } label: {
                    MetricRow(title: "İncelenmeli", value: report.reviewClusters.count)
                }

                MetricRow(title: "Aynı numara grubu", value: report.samePhoneGroupCount)
                MetricRow(title: "Aynı e-posta grubu", value: report.sameEmailGroupCount)
                MetricRow(title: "İsimsiz kayıt", value: report.unnamedCount)
            }

            Section("Toplu İşlemler") {
                Button {
                    showBulkConfirmation = true
                } label: {
                    Label("Güvenli Kesin Duplicate'leri Birleştir", systemImage: "person.2.badge.checkmark")
                }
                .disabled(report.definiteClusters.isEmpty || (!report.notesAccessAvailable && !viewModel.allowWithoutNotesEntitlement))
                .confirmationDialog(
                    "Kesin duplicate'ler toplu birleştirilsin mi?",
                    isPresented: $showBulkConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Yedekle ve Birleştir", role: .destructive) {
                        viewModel.bulkMergeDefinite()
                    }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Yalnızca kesin, hard-conflict içermeyen ve scalar çakışması olmayan kümeler işlenir. Önce tüm rehberin yedeği alınır.")
                }

                Button {
                    showConsolidationConfirmation = true
                } label: {
                    Label("Benzersiz Kayıtları iCloud'a Taşı", systemImage: "icloud.and.arrow.up")
                }
                .disabled(report.preferredICloudContainerID == nil || (!report.notesAccessAvailable && !viewModel.allowWithoutNotesEntitlement))
                .confirmationDialog(
                    "Rehber iCloud'da konsolide edilsin mi?",
                    isPresented: $showConsolidationConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Yedekle ve Taşı", role: .destructive) {
                        viewModel.consolidateUniqueContactsToICloud()
                    }
                    Button("Vazgeç", role: .cancel) {}
                } message: {
                    Text("Duplicate kümelerinde bulunan kişiler atlanır. Yalnızca benzersiz Gmail, Exchange, CardDAV veya yerel kayıtlar iCloud'a kopyalanır, doğrulanır ve sonra eski kaynaktan silinir.")
                }
            }

            if !viewModel.operationHistory.isEmpty {
                Section("İşlem Geçmişi / Undo") {
                    ForEach(viewModel.operationHistory.prefix(20)) { operation in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(operation.kind == .merge ? "Merge" : "iCloud'a taşıma")
                                    .font(.subheadline.weight(.semibold))
                                Text(operation.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Geri Al") {
                                viewModel.undo(operation)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            Section {
                Button("Yeniden Tara", action: viewModel.scan)
            } footer: {
                Text("Silme yalnızca yeni/master kayıt kaydedilip tekrar okunarak doğrulandıktan sonra yapılır. Riskli eşleşmeler toplu işleme girmez.")
            }
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: Int

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value.formatted())
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }
}
