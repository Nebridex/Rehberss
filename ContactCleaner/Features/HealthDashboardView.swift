import SwiftUI

struct HealthDashboardView: View {
    let report: HealthReport
    let rescan: () -> Void

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

            Section("Duplicate Analizi") {
                NavigationLink {
                    DuplicateListView(title: "Kesin duplicate", clusters: report.definiteClusters)
                } label: {
                    MetricRow(title: "Kesin duplicate", value: report.definiteClusters.count)
                }

                NavigationLink {
                    DuplicateListView(title: "Yüksek olasılıklı", clusters: report.highClusters)
                } label: {
                    MetricRow(title: "Yüksek olasılıklı", value: report.highClusters.count)
                }

                NavigationLink {
                    DuplicateListView(title: "İncelenmeli", clusters: report.reviewClusters)
                } label: {
                    MetricRow(title: "İncelenmeli", value: report.reviewClusters.count)
                }

                MetricRow(title: "Aynı numara grubu", value: report.samePhoneGroupCount)
                MetricRow(title: "Aynı e-posta grubu", value: report.sameEmailGroupCount)
                MetricRow(title: "İsimsiz kayıt", value: report.unnamedCount)
            }

            Section {
                Button("Yeniden Tara", action: rescan)
            } footer: {
                Text("Read-only build: Bu sürüm rehberde hiçbir kayıt oluşturmaz, değiştirmez veya silmez.")
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
