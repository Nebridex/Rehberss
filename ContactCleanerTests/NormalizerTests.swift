import XCTest
@testable import ContactCleaner

final class NormalizerTests: XCTestCase {
    func testTurkishPhoneVariantsMatch() {
        let values = [
            "0532 123 45 67",
            "5321234567",
            "+90 532 123 45 67",
            "0090 532 123 45 67",
            "90 532 123 45 67"
        ]
        XCTAssertEqual(Set(values.map { PhoneNormalizer.normalize($0) }), ["+905321234567"])
    }

    func testTurkishNamesNormalize() {
        XCTAssertEqual(NameNormalizer.normalize("Yılmaz"), "yilmaz")
        XCTAssertEqual(NameNormalizer.normalize("Yilmaz"), "yilmaz")
        XCTAssertEqual(NameNormalizer.normalize("Çağrı Şahin"), "cagri sahin")
        XCTAssertEqual(NameNormalizer.normalize("Cagri Sahin"), "cagri sahin")
    }

    func testEmailsCaseInsensitive() {
        XCTAssertEqual(EmailNormalizer.normalize(" Cihat.Oz@Example.COM "), "cihat.oz@example.com")
    }

    func testSameNameDifferentNumbersRequiresReview() {
        let contacts = [
            makeContact(id: "a", given: "Cihat", family: "Öz", phone: "0532 111 22 33"),
            makeContact(id: "b", given: "Cihat", family: "Öz", phone: "0544 555 66 77")
        ]
        let analysis = DuplicateEngine().analyze(contacts)
        XCTAssertEqual(analysis.clusters.count, 1)
        XCTAssertEqual(analysis.clusters.first?.confidence, .review)
    }

    func testSameNameSameNormalizedPhoneIsDefinite() {
        let contacts = [
            makeContact(id: "a", given: "Cihat", family: "Öz", phone: "0532 111 22 33"),
            makeContact(id: "b", given: "Cihat", family: "Oz", phone: "+90 532 111 22 33")
        ]
        let analysis = DuplicateEngine().analyze(contacts)
        XCTAssertEqual(analysis.clusters.count, 1)
        XCTAssertEqual(analysis.clusters.first?.confidence, .definite)
    }

    private func makeContact(id: String, given: String, family: String, phone: String) -> ContactSnapshot {
        ContactSnapshot(
            id: id,
            source: ContactSource(id: "icloud", name: "iCloud", kind: .iCloud),
            namePrefix: "",
            givenName: given,
            middleName: "",
            familyName: family,
            previousFamilyName: "",
            nameSuffix: "",
            nickname: "",
            phoneticGivenName: "",
            phoneticMiddleName: "",
            phoneticFamilyName: "",
            organizationName: "",
            departmentName: "",
            jobTitle: "",
            phones: [LabeledString(label: "mobile", value: phone)],
            emails: [],
            postalAddresses: [],
            urlAddresses: [],
            relations: [],
            dates: [],
            socialProfiles: [],
            instantMessages: [],
            birthday: nil,
            nonGregorianBirthday: nil,
            imageData: nil,
            note: nil,
            groups: []
        )
    }
}
