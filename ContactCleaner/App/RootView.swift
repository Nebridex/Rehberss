import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = HealthViewModel()

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.state {
                case .idle:
                    welcomeView
                case .requestingPermission:
                    ProgressView("Rehber izni isteniyor…")
                case .scanning(let progress):
                    VStack(spacing: 18) {
                        ProgressView()
                        Text("Rehber taranıyor…")
                            .font(.headline)
                        Text(progress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                case .loaded(let report):
                    HealthDashboardView(report: report, rescan: viewModel.scan)
                case .limited:
                    ContentUnavailableView(
                        "Tam Rehber Erişimi Gerekli",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Bu araç tüm rehberi karşılaştırdığı için iOS Ayarlar > Uygulamalar > ContactCleaner > Kişiler bölümünden tüm kişilere erişim ver.")
                    )
                case .denied:
                    ContentUnavailableView(
                        "Rehber Erişimi Kapalı",
                        systemImage: "lock.fill",
                        description: Text("Ayarlar'dan ContactCleaner için Kişiler erişimini aç.")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Tarama Başarısız",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Rehber Temizleyici")
        }
        .task {
            await viewModel.refreshAuthorization()
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 62))

            VStack(spacing: 8) {
                Text("Rehberini Analiz Et")
                    .font(.title2.bold())
                Text("Bu ilk sürüm yalnızca okur. Hiçbir kişi oluşturmaz, değiştirmez veya silmez.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("iCloud, Gmail, Exchange ve yerel kayıtları tara", systemImage: "checkmark.circle")
                Label("Türkçe isim ve telefon formatlarını normalize et", systemImage: "checkmark.circle")
                Label("Kesin, yüksek olasılıklı ve incelenmeli eşleşmeleri ayır", systemImage: "checkmark.circle")
            }
            .font(.subheadline)

            Button(action: viewModel.scan) {
                Text("Rehberi Tara")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }
}
