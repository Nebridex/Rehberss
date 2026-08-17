import SwiftUI

struct DuplicateDetailView: View {
    let cluster: PersonCluster

    var body: some View {
        List {
            Section {
                LabeledContent("Güven", value: cluster.confidence.rawValue)
                LabeledContent("Kayıt", value: "\(cluster.contacts.count)")
                if cluster.hasHardConflict {
                    Label("Bu grup otomatik birleştirmeye uygun değil.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Neden eşleşti?") {
                ForEach(cluster.evidence) { item in
                    Label(item.detail, systemImage: item.kind == .birthdayConflict ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }

            ForEach(cluster.contacts) { contact in
                Section(contact.source.name) {
                    LabeledContent("Ad", value: contact.displayName)
                    if !contact.organizationName.isEmpty {
                        LabeledContent("Şirket", value: contact.organizationName)
                    }
                    if !contact.jobTitle.isEmpty {
                        LabeledContent("Unvan", value: contact.jobTitle)
                    }
                    ForEach(contact.phones) { phone in
                        LabeledContent(phone.label, value: phone.value)
                    }
                    ForEach(contact.emails) { email in
                        LabeledContent(email.label, value: email.value)
                    }
                }
            }

            Section {
                Text("Birleştirme bu read-only build'de kapalıdır.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(cluster.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
