import XCTest
@testable import RouteBarCore

final class LocalizationTests: XCTestCase {
    func testCatalogHasAllThreeLanguagesAndMatchingPlaceholders() throws {
        XCTAssertGreaterThan(RouteBarLocalization.catalog.count, 190)
        let regex = try NSRegularExpression(pattern: "\\{([0-9]+)\\}")
        func placeholders(_ text: String) -> [String] {
            let source = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }.sorted()
        }
        for (key, translations) in RouteBarLocalization.catalog {
            XCTAssertEqual(Set(translations.keys), ["en", "zh-Hant", "zh-Hans"], key)
            for (language, text) in translations {
                XCTAssertFalse(text.isEmpty, "\(language): \(key)")
                XCTAssertEqual(placeholders(key), placeholders(text), "\(language): \(key)")
            }
        }
    }
    func testApplyLabelsAndReviewConfirmationInAllLanguages() {
        for (language, apply, confirm, review) in [
            (AppLanguage.english, "Apply", "Confirm and Apply", "Review Route Changes"),
            (.traditionalChinese, "套用", "確認並套用", "預覽路由變更"),
            (.simplifiedChinese, "应用", "确认并应用", "预览路由更改")
        ] {
            XCTAssertEqual(RouteBarLocalization.text("应用", language: language), apply)
            XCTAssertEqual(RouteBarLocalization.text("确认并应用", language: language), confirm)
            XCTAssertEqual(RouteBarLocalization.text("预览路由更改", language: language), review)
        }
    }
    func testSystemLanguageResolution() {
        XCTAssertEqual(AppLanguage.resolve(["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(["zh_HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(["zh-Hant-US"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage.resolve(["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(["zh-Hans-TW"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.resolve(["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage.resolve(["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.resolve(["fr-FR", "zh-Hant"]), .traditionalChinese)
    }
    func testInterpolationReorderingAndArgumentsAreNotReinterpreted() {
        XCTAssertEqual(RouteBarLocalization.text("与 {0} 的 {1} 重叠", arguments: ["en0", "10.20.4.0/23"], language: .english), "Overlaps 10.20.4.0/23 on en0")
        XCTAssertEqual(RouteBarLocalization.text("与 {0} 的 {1} 重叠", arguments: ["{1}", "{0}"], language: .english), "Overlaps {0} on {1}")
        XCTAssertEqual(RouteBarLocalization.text("unrecognized key", language: .english), "unrecognized key")
    }
    func testOldSavedActivityMessagesRelocalizeWithNestedSummaries() {
        XCTAssertEqual(RouteBarLocalization.relocalize("蒲公英 · 仅选定节点 · 已验证", language: .english), "Pgy · Selected Nodes Only · Verified")
        XCTAssertEqual(RouteBarLocalization.relocalize("Pgy · Selected Nodes Only · Verified", language: .traditionalChinese), "蒲公英 · 僅選取的節點 · 已驗證")
        XCTAssertEqual(RouteBarLocalization.relocalize("节点 IP 无效：172.16.0.26", language: .english), "Invalid node IP: 172.16.0.26")
        XCTAssertEqual(RouteBarLocalization.relocalize("Interface error from macOS", language: .traditionalChinese), "Interface error from macOS")
    }
    func testHelperLanguageRoundTripAndLegacyRequestCompatibility() throws {
        let request = ChangeRequest(kind: .applyTailscale, settings: AppSettings(), uid: 501, expectedFingerprint: "read-only-test", language: .traditionalChinese)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(ChangeRequest.self, from: data).language, .traditionalChinese)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "language")
        XCTAssertNil(try JSONDecoder().decode(ChangeRequest.self, from: JSONSerialization.data(withJSONObject: json)).language)
    }
    func testSelectionPersistenceDoesNotAlterNetworkSettings() {
        let existing = UserDefaults.standard.object(forKey: RouteBarLocalization.preferenceKey)
        defer {
            if let existing { UserDefaults.standard.set(existing, forKey: RouteBarLocalization.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: RouteBarLocalization.preferenceKey) }
            RouteBarLocalization.useInCurrentProcess(nil)
        }
        let settingsBefore = try? Data(contentsOf: AppSettings.directory.appendingPathComponent("settings.json"))
        RouteBarLocalization.selection = .traditionalChinese
        XCTAssertEqual(RouteBarLocalization.selection, .traditionalChinese)
        XCTAssertEqual(RouteBarLocalization.language, .traditionalChinese)
        XCTAssertEqual(L("应用"), "套用")
        RouteBarLocalization.useInCurrentProcess(.english)
        XCTAssertEqual(L("应用"), "Apply")
        XCTAssertEqual(try? Data(contentsOf: AppSettings.directory.appendingPathComponent("settings.json")), settingsBefore)
    }
}
