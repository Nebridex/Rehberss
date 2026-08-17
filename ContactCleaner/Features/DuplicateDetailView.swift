import SwiftUI

struct DuplicateDetailView: View {
    let cluster: PersonCluster
    @ObservedObject var viewModel: HealthViewModel

    @State private var showMergeConfirmation = false
    @State private var confirmScalarConflicts = false

    var body: some View {
        let preview = viewModel.preview(for: cluster)

        List {
            Section {
                LabeledContent("Güven", value: cluster.confidence.rawValue)
                LabeledContent("Kayıt", value: "\(cluster.contacts.count)")
                if cluster.hasHardConflict {
                    Label("Bu grup toplu birleştirmeye uygun değil; yalnızca manuel onayla işlenebilir.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Neden eşleşti?") {
                ForEach(cluster.evidence) { item in
                    Label(item.detail, systemImage: item.kind == .birthdayConflict ? "exclamationmark.triangle" : "checkmark.circle")
                }
            }

            Section("Önce — Kaynak Kayıtlar") {
                ForEach(cluster.contacts) { contact in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(contact.displayName).font(.headline)
                            Spacer()
                            Text(contact.source.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if !contact.organizationName.isEmpty { Text("Şirket: \(contact.organizationName)") }
                        if !contact.jobTitle.isEmpty { Text("Unvan: \(contact.jobTitle)") }
                        ForEach(contact.phones) { phone in Text("\(phone.label): \(phone.value)") }
                        ForEach(contact.emails) { email in Text("\(email.label): \(email.value)") }
                        if !contact.postalAddresses.isEmpty { Text("\(contact.postalAddresses.count) adres") }
                        if contact.hasImage { Label("Fotoğraf var", systemImage: "photo") }
                        if contact.note != nil { Label("Not var", systemImage: "note.text") }
                    }
                    .font(.subheadline)
                    .padding(.vertical, 3)
                }
            }

            if let preview {
                Section("Sonra — iCloud Master") {
                    LabeledContent("Ad", value: preview.displayName)
                    if !preview.organizationName.isEmpty { LabeledContent("Şirket", value: preview.organizationName) }
                    if !preview.departmentName.isEmpty { LabeledContent("Departman", value: preview.departmentName) }
                    if !preview.jobTitle.isEmpty { LabeledContent("Unvan", value: preview.jobTitle) }
                    ForEach(preview.phones) { phone in LabeledContent(phone.label, value: phone.value) }
                    ForEach(preview.emails) { email in LabeledContent(email.label, value: email.value) }
                    if let birthday = preview.selectedBirthday {
                        LabeledContent("Doğum günü", value: formattedBirthday(birthday))
                    }
                }

                if !preview.warnings.isEmpty {
                    Section("Dikkat") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if preview.requiresExplicitConflictConfirmation {
                            Toggle("Bu scalar çakışmaları gördüm ve master değerini kabul ediyorum", isOn: $confirmScalarConflicts)
                        }
                    }
                }

                Section {
                    if !viewModel.allowWithoutNotesEntitlement && cluster.contacts.allSatisfy({ $0.note == nil }) {
                        Text("Notes entitlement yoksa uygulama contact notlarının varlığını doğrulayamaz; dashboard'daki güvenlik seçeneği açılmadan destructive işlem başlamaz.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showMergeConfirmation = true
                    } label: {
                        Label("Bu Kayıtları Birleştir", systemImage: "person.2.badge.checkmark")
                    }
                    .disabled(preview.requiresExplicitConflictConfirmation && !confirmScalarConflicts)
                    .confirmationDialog(
                        "Bu kişiler tek iCloud kaydında birleştirilsin mi?",
                        isPresented: $showMergeConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Yedekle, Birleştir ve Doğrula", role: .destructive) {
                            viewModel.merge(cluster, confirmScalarConflicts: confirmScalarConflicts)
                        }
                        Button("Vazgeç", role: .cancel) {}
                    } message: {
                        Text("Önce snapshot/vCard yedeği alınır. Master kayıt kaydedilip yeniden okunarak doğrulanmadan hiçbir kaynak kayıt silinmez.")
                    }
                }
            } else {
                Section {
                    Label("iCloud master container bulunamadığı için merge kapalı.", systemImage: "icloud.slash")
                }
            }
        }
        .navigationTitle(cluster.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formattedBirthday(_ value: DateComponents) -> String {
        let day = value.day.map(String.init) ?? "?"
        let month = value.month.map(String.init) ?? "?"
        let year = value.year.map(String.init) ?? "?"
        return "\(day).\(month).\(year)"
    }
}
