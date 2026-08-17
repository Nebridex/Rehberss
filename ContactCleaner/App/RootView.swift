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
                        Text("Rehber taranıyor…").font(.headline)
                        Text(progress).font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding()
                case .loaded(let report):
                    HealthDashboardView(report: report, viewModel: viewModel)
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
                        "İşlem Başarısız",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Rehber Temizleyici")
            .safeAreaInset(edge: .bottom) {
                maintenanceBanner
            }
        }
        .task { await viewModel.refreshAuthorization() }
    }

    @ViewBuilder
    private var maintenanceBanner: some View {
        switch viewModel.maintenanceState {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 12) {
                ProgressView()
                Text(text).font(.footnote)
                Spacer()
            }
            .padding()
            .background(.ultraThinMaterial)
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.ultraThinMaterial)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.ultraThinMaterial)
        }
    }

    private var welcomeView: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 62))

            VStack(spacing: 8) {
                Text("Rehberini Güvenle Temizle")
                    .font(.title2.bold())
                Text("Önce tüm kaynakları tarar. Merge ve silme işlemlerinden önce cihazda yedek oluşturur ve sonucu doğrular.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("iCloud, Gmail, Exchange ve yerel kayıtları tara", systemImage: "checkmark.circle")
                Label("Türkçe isim ve telefon formatlarını normalize et", systemImage: "checkmark.circle")
                Label("Merge öncesi sonucu göster, işlem geçmişinden geri al", systemImage: "checkmark.circle")
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
