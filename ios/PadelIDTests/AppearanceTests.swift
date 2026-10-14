import Testing
import SwiftUI
import UIKit
@testable import PadelID

@MainActor
@Suite("Appearance and system icon selection")
struct AppearanceTests {
    @Test func builtBundleContainsBothAlternateIconsAndTheirPreviews() throws {
        let bundle = Bundle(for: IconBundleMarker.self)
        // Tests are hosted by the app; Bundle.main is the product under test.
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        #expect(Set(alternates.keys) == ["AppIconCharcoal", "AppIconBall"])
        for choice in AppIconChoice.allCases {
            #expect(UIImage(named: choice.previewName, in: .main, compatibleWith: nil) != nil)
        }
        #expect(bundle.bundleURL.pathExtension == "xctest")
    }
    @Test func automaticFollowsTheSystem() {
        #expect(AppAppearance.automatic.colorScheme == nil)
        #expect(AppAppearance.light.colorScheme == .light)
        #expect(AppAppearance.dark.colorScheme == .dark)
    }

    @Test func restoresSystemChoiceAndReturnsToPrimary() async {
        let system = IconSystemStub(name: "AppIconBall")
        let selection = AppIconSelection(system: system)
        #expect(selection.selected == .ball)
        await selection.choose(.charcoal)
        #expect(system.alternateIconName == "AppIconCharcoal")
        #expect(selection.selected == .charcoal)
        await selection.choose(.lime)
        #expect(system.alternateIconName == nil)
        #expect(selection.selected == .lime)
        #expect(!selection.isChanging)
    }

    @Test func failureKeepsTheActualIconSelected() async {
        let system = IconSystemStub(name: nil)
        system.shouldFail = true
        let selection = AppIconSelection(system: system)
        await selection.choose(.ball)
        #expect(selection.selected == .lime)
        #expect(selection.errorMessage != nil)
        #expect(!selection.isChanging)
    }

    @Test func doesNotCallUnsupportedOrUnchangedSelection() async {
        let system = IconSystemStub(name: nil)
        let selection = AppIconSelection(system: system)
        await selection.choose(.lime)
        #expect(system.calls == 0)
        system.supportsAlternateIcons = false
        await selection.choose(.ball)
        #expect(system.calls == 0)
        #expect(selection.selected == .lime)
        #expect(selection.errorMessage != nil)
    }

    @Test func refreshReadsChangesMadeByTheSystem() {
        let system = IconSystemStub(name: nil)
        let selection = AppIconSelection(system: system)
        system.alternateIconName = "AppIconBall"
        selection.refresh()
        #expect(selection.selected == .ball)
        system.alternateIconName = "UnknownFutureIcon"
        selection.refresh()
        #expect(selection.selected == nil)
    }
}

private final class IconBundleMarker: NSObject {}

@MainActor
private final class IconSystemStub: AppIconChanging {
    var supportsAlternateIcons = true
    var alternateIconName: String?
    var shouldFail = false
    var calls = 0
    init(name: String?) { alternateIconName = name }
    func changeIcon(to name: String?) async throws {
        calls += 1
        if shouldFail { throw IconFailure.rejected }
        alternateIconName = name
    }
    enum IconFailure: Error { case rejected }
}
