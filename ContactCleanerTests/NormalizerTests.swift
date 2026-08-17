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
        XCTAssertEqual(Set(values.compactMap(PhoneNormalizer.normalize)), ["+905321234567"])
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
}
