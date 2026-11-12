import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Indie_Dev_Buddy

struct AppShowcaseTests {
    @Test func platformRecognitionUsesCanonicalNamesAndExplicitAliases() {
        let values = [
            " tv_os ", "Vision_OS", "iPad", "iphone", "OS X", "MAC_OS",
            "Apple TV", "watchOS", "tvOS", "visionOS", "iOS", "macOS",
            "Mac Catalyst", "iPhone OS", "iOS App", ""
        ]

        #expect(ShowcasePlatform.supported(by: values) == [
            .macOS, .iOS, .iPadOS, .watchOS, .tvOS, .visionOS
        ])
    }

    @Test func platformRecognitionDeduplicatesAndReturnsCanonicalOrder() {
        let values = ["VISION_OS", "iOS", "mac", "iPhone", "iPad", "Apple TV", "watchOS", "OS X"]

        #expect(ShowcasePlatform.supported(by: values) == [
            .macOS, .iOS, .iPadOS, .watchOS, .tvOS, .visionOS
        ])
    }

    @Test func platformRecognitionDoesNotInferDeviceSupport() {
        #expect(ShowcasePlatform.supported(by: ["iOS", "Designed for iPad", "Compatible with Apple Vision Pro"]) == [.iOS])
        #expect(ShowcasePlatform.supported(by: ["unknown", "iOS on Apple Vision Pro"]).isEmpty)
    }

    @Test func showcaseSettingsHaveExpectedDefaultsAndPixelSizes() {
        let settings = AppShowcaseSettings()

        #expect(settings.format == .portrait)
        #expect(settings.layout == .list)
        #expect(settings.selectedIDs.isEmpty)
        #expect(ShowcaseFormat.portrait.pixelSize == CGSize(width: 1080, height: 1350))
        #expect(ShowcaseFormat.square.pixelSize == CGSize(width: 1080, height: 1080))
        #expect(ShowcaseFormat.landscape.pixelSize == CGSize(width: 1920, height: 1080))
    }

    @Test func selectionFiltersByIDWhilePreservingAppOrder() {
        let first = AppRecord(id: "first", name: "First")
        let second = AppRecord(id: "second", name: "Second")
        let third = AppRecord(id: "third", name: "Third")
        var settings = AppShowcaseSettings()
        settings.selectedIDs = [third.id, first.id, "missing"]

        #expect(settings.selection(from: [first, second, third]) == [first, third])
    }

    @Test(arguments: ShowcaseFormat.allCases)
    func gridCanFitThirtyAppsInEveryFormat(format: ShowcaseFormat) {
        var settings = AppShowcaseSettings()
        settings.format = format

        #expect(settings.capacity(for: .grid) >= 30)
        #expect(settings.capacity(for: .list) < settings.capacity(for: .grid))
    }

    @Test @MainActor func rendererRejectsEmptyAndOverflowingSelections() {
        let settings = AppShowcaseSettings()
        let apps = (0...settings.capacity(for: .list)).map { AppRecord(name: "App \($0)") }
        let empty = AppShowcaseArtwork(apps: [], icons: [:], settings: settings)
        let overflow = AppShowcaseArtwork(apps: apps, icons: [:], settings: settings)

        #expect(throws: CocoaError.self) { try empty.pngData() }
        #expect(throws: CocoaError.self) { try overflow.pngData() }
    }

    @Test @MainActor func artworkPNGDecodesAtSinglePortraitSize() throws {
        let app = AppRecord(id: "single", name: "Single App")
        let artwork = AppShowcaseArtwork(apps: [app], icons: [:], settings: AppShowcaseSettings())

        try expectPNGSize(artwork.pngData(), width: 1080, height: 1350)
    }

    @Test @MainActor func artworkPNGDecodesAtSquareSizeForThirtyGridItems() throws {
        let apps = (0..<30).map { AppRecord(id: "app-\($0)", name: "App \($0)") }
        var settings = AppShowcaseSettings()
        settings.format = .square
        settings.layout = .grid
        let artwork = AppShowcaseArtwork(apps: apps, icons: [:], settings: settings)

        try expectPNGSize(artwork.pngData(), width: 1080, height: 1080)
    }

    @Test @MainActor func artworkPNGDecodesAtLandscapeSize() throws {
        var settings = AppShowcaseSettings()
        settings.format = .landscape
        let artwork = AppShowcaseArtwork(
            apps: [AppRecord(id: "wide", name: "Wide App")],
            icons: [:],
            settings: settings
        )

        try expectPNGSize(artwork.pngData(), width: 1920, height: 1080)
    }

    @MainActor
    private func expectPNGSize(_ data: Data, width: Int, height: Int) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? Int) == width)
        #expect((properties[kCGImagePropertyPixelHeight] as? Int) == height)
        #expect(CGImageSourceGetType(source) == UTType.png.identifier as CFString)
    }
}
