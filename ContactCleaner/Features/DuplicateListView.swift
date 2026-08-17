import SwiftUI

struct DuplicateListView: View {
    let title: String
    let clusters: [PersonCluster]
    @ObservedObject var viewModel: HealthViewModel

    var body: some View {
        List(clusters) { cluster in
            NavigationLink {
                DuplicateDetailView(cluster: cluster, viewModel: viewModel)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(cluster.title)
                        .font(.headline)
                    HStack {
                        Text("\(cluster.contacts.count) kayıt")
                        if cluster.hasHardConflict { Text("• çakışma var") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .overlay {
            if clusters.isEmpty {
                ContentUnavailableView("Eşleşme Yok", systemImage: "checkmark.circle")
            }
        }
    }
}
