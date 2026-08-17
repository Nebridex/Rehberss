import Foundation

struct DuplicateEngine {
    struct Analysis {
        let clusters: [PersonCluster]
        let samePhoneGroups: Int
        let sameEmailGroups: Int
        let unnamedCount: Int
    }

    func analyze(_ contacts: [ContactSnapshot]) -> Analysis {
        let phoneIndex = makeIndex(contacts: contacts) { contact in
            contact.phones.compactMap { PhoneNormalizer.normalize($0.value) }
        }
        let emailIndex = makeIndex(contacts: contacts) { contact in
            contact.emails.compactMap { EmailNormalizer.normalize($0.value) }
        }
        let nameIndex = makeIndex(contacts: contacts) { contact in
            let name = NameNormalizer.fullName(contact)
            return name.isEmpty ? [] : [name]
        }

        var pairKeys = Set<PairKey>()
        appendPairs(from: phoneIndex, into: &pairKeys)
        appendPairs(from: emailIndex, into: &pairKeys)
        appendPairs(from: nameIndex, into: &pairKeys)

        // Controlled fuzzy candidates: same normalized surname or same first token.
        let fuzzyBuckets = makeIndex(contacts: contacts) { contact in
            let name = NameNormalizer.fullName(contact)
            let tokens = name.split(separator: " ").map(String.init)
            guard !tokens.isEmpty else { return [] }
            var keys = ["first:\(tokens[0])"]
            if tokens.count > 1 { keys.append("last:\(tokens[tokens.count - 1])") }
            return keys
        }
        appendPairs(from: fuzzyBuckets, maxBucketSize: 40, into: &pairKeys)

        let byID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        var pairs: [DuplicatePair] = []

        for key in pairKeys {
            guard let left = byID[key.a], let right = byID[key.b] else { continue }
            if let pair = evaluate(left, right) {
                pairs.append(pair)
            }
        }

        let clusters = buildClusters(contacts: contacts, pairs: pairs)

        return Analysis(
            clusters: clusters,
            samePhoneGroups: phoneIndex.values.filter { $0.count > 1 }.count,
            sameEmailGroups: emailIndex.values.filter { $0.count > 1 }.count,
            unnamedCount: contacts.filter { NameNormalizer.fullName($0).isEmpty && $0.organizationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        )
    }

    private func evaluate(_ a: ContactSnapshot, _ b: ContactSnapshot) -> DuplicatePair? {
        let nameA = NameNormalizer.fullName(a)
        let nameB = NameNormalizer.fullName(b)
        let exactName = !nameA.isEmpty && nameA == nameB
        let nameSimilarity = StringSimilarity.normalizedLevenshtein(nameA, nameB)

        let phonesA = Set(a.phones.compactMap { PhoneNormalizer.normalize($0.value) })
        let phonesB = Set(b.phones.compactMap { PhoneNormalizer.normalize($0.value) })
        let exactPhone = !phonesA.intersection(phonesB).isEmpty

        let emailsA = Set(a.emails.compactMap { EmailNormalizer.normalize($0.value) })
        let emailsB = Set(b.emails.compactMap { EmailNormalizer.normalize($0.value) })
        let exactEmail = !emailsA.intersection(emailsB).isEmpty

        let companyA = CompanyNormalizer.normalize(a.organizationName)
        let companyB = CompanyNormalizer.normalize(b.organizationName)
        let sameCompany = !companyA.isEmpty && companyA == companyB

        let birthdayConflict = birthdaysConflict(a.birthday, b.birthday)
        let sameBirthday = birthdaysEqual(a.birthday, b.birthday)

        var score = 0
        var evidence: [MatchEvidence] = []

        if exactPhone {
            score += 55
            evidence.append(.init(kind: .exactPhone, detail: "Telefon numarası aynı"))
        }
        if exactEmail {
            score += 50
            evidence.append(.init(kind: .exactEmail, detail: "E-posta aynı"))
        }
        if exactName {
            score += 30
            evidence.append(.init(kind: .exactName, detail: "Ad soyad aynı"))
        } else if nameSimilarity >= 0.92, !nameA.isEmpty, !nameB.isEmpty {
            score += 22
            evidence.append(.init(kind: .similarName, detail: "Ad soyad çok benzer"))
        } else if nameSimilarity >= 0.84, !nameA.isEmpty, !nameB.isEmpty {
            score += 14
            evidence.append(.init(kind: .similarName, detail: "Ad soyad benzer"))
        }
        if sameCompany {
            score += 15
            evidence.append(.init(kind: .sameCompany, detail: "Şirket aynı"))
        }
        if sameBirthday {
            score += 20
            evidence.append(.init(kind: .sameBirthday, detail: "Doğum günü aynı"))
        }
        if birthdayConflict {
            score -= 100
            evidence.append(.init(kind: .birthdayConflict, detail: "Doğum günleri farklı"))
        }

        let hasHardConflict = birthdayConflict
        let confidence: DuplicateConfidence?

        if hasHardConflict {
            confidence = (exactPhone || exactEmail || exactName) ? .review : nil
        } else if (exactPhone && (exactName || nameSimilarity >= 0.84)) ||
                    (exactEmail && (exactName || nameSimilarity >= 0.84)) ||
                    (exactPhone && exactEmail) {
            confidence = .definite
        } else if (exactName && sameCompany) ||
                    ((exactPhone || exactEmail) && nameSimilarity >= 0.72) ||
                    (nameSimilarity >= 0.94 && sameCompany) {
            confidence = .high
        } else if exactName ||
                    (nameSimilarity >= 0.90 && (!phonesA.isEmpty || !phonesB.isEmpty || !emailsA.isEmpty || !emailsB.isEmpty)) {
            // Same full name with different numbers intentionally lands here for manual review.
            confidence = .review
        } else {
            confidence = nil
        }

        guard let confidence else { return nil }
        return DuplicatePair(
            leftID: a.id,
            rightID: b.id,
            confidence: confidence,
            score: score,
            evidence: evidence,
            hasHardConflict: hasHardConflict
        )
    }

    private func buildClusters(contacts: [ContactSnapshot], pairs: [DuplicatePair]) -> [PersonCluster] {
        var union = UnionFind(ids: contacts.map(\.id))
        for pair in pairs {
            union.union(pair.leftID, pair.rightID)
        }

        let contactByID = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        let pairLookup = Dictionary(grouping: pairs) { union.find($0.leftID) }
        let groupedIDs = Dictionary(grouping: contacts.map(\.id)) { union.find($0) }

        var clusters: [PersonCluster] = []

        for (root, ids) in groupedIDs where ids.count > 1 {
            let members = ids.compactMap { contactByID[$0] }
            let memberIDSet = Set(ids)
            let relevantPairs = (pairLookup[root] ?? pairs.filter {
                memberIDSet.contains($0.leftID) && memberIDSet.contains($0.rightID)
            }).filter { memberIDSet.contains($0.leftID) && memberIDSet.contains($0.rightID) }

            guard !relevantPairs.isEmpty else { continue }

            var confidence = relevantPairs.min(by: { $0.confidence.rank < $1.confidence.rank })?.confidence ?? .review
            var hardConflict = relevantPairs.contains(where: \.hasHardConflict)

            // Transitive cluster safety: if not every member pair has an accepted edge, force manual review.
            let expectedPairCount = ids.count * (ids.count - 1) / 2
            if relevantPairs.count < expectedPairCount {
                confidence = .review
                hardConflict = true
            }

            let evidence = Array(Set(relevantPairs.flatMap(\.evidence)))
                .sorted { $0.detail < $1.detail }

            clusters.append(PersonCluster(
                id: root,
                contacts: members.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
                confidence: confidence,
                evidence: evidence,
                hasHardConflict: hardConflict
            ))
        }

        return clusters.sorted {
            if $0.confidence.rank != $1.confidence.rank { return $0.confidence.rank > $1.confidence.rank }
            return $0.contacts.count > $1.contacts.count
        }
    }

    private func makeIndex(contacts: [ContactSnapshot], keys: (ContactSnapshot) -> [String]) -> [String: Set<String>] {
        var index: [String: Set<String>] = [:]
        for contact in contacts {
            for key in Set(keys(contact)).filter({ !$0.isEmpty }) {
                index[key, default: []].insert(contact.id)
            }
        }
        return index
    }

    private func appendPairs(from index: [String: Set<String>], maxBucketSize: Int = 100, into pairs: inout Set<PairKey>) {
        for idsSet in index.values where idsSet.count > 1 && idsSet.count <= maxBucketSize {
            let ids = idsSet.sorted()
            for i in 0..<(ids.count - 1) {
                for j in (i + 1)..<ids.count {
                    pairs.insert(PairKey(ids[i], ids[j]))
                }
            }
        }
    }

    private func birthdaysEqual(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        guard let a, let b, a.month != nil, a.day != nil, b.month != nil, b.day != nil else { return false }
        return a.year == b.year && a.month == b.month && a.day == b.day
    }

    private func birthdaysConflict(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        guard let a, let b, a.month != nil, a.day != nil, b.month != nil, b.day != nil else { return false }
        if let ay = a.year, let by = b.year, ay != by { return true }
        return a.month != b.month || a.day != b.day
    }
}

private struct PairKey: Hashable {
    let a: String
    let b: String

    init(_ x: String, _ y: String) {
        if x <= y { a = x; b = y } else { a = y; b = x }
    }
}

private struct UnionFind {
    private var parent: [String: String]

    init(ids: [String]) {
        parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
    }

    mutating func find(_ id: String) -> String {
        guard let p = parent[id] else { return id }
        if p == id { return id }
        let root = find(p)
        parent[id] = root
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[rb] = ra }
    }
}
