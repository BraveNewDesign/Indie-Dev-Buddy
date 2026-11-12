import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Indie_Dev_Buddy

struct AssetLibraryTests {
    @Test func appStoreConnectScreenshotImportMetadataRoundTripsAndOldAssetsDecode() throws {
        let asset = WorkspaceAsset(
            id: UUID(), fileExtension: "png", originalFilename: "remote.png", name: "Remote Screenshot",
            owner: AssetOwner(.app, "local-app"), folderID: nil, category: .marketing, tags: [],
            appStoreConnectScreenshotID: "remote-screenshot-123", added: Date(timeIntervalSince1970: 10)
        )
        let set = ScreenshotSet(
            appID: "local-app", platform: .iPad, categoryID: "ipad-13", locale: "en-US",
            version: "2.1", name: "App Store Connect", assetIDs: [asset.id],
            appStoreConnectSetID: "remote-set-456", appStoreConnectDisplayType: "APP_IPAD_PRO_3GEN_129"
        )
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(AssetLibrary(assets: [asset], screenshotSets: [set]))
        let restored = try JSONDecoder().decode(AssetLibrary.self, from: encoded)
        #expect(restored.assets.first?.appStoreConnectScreenshotID == "remote-screenshot-123")
        #expect(restored.screenshotSets.first?.appStoreConnectSetID == "remote-set-456")
        #expect(restored.screenshotSets.first?.appStoreConnectDisplayType == "APP_IPAD_PRO_3GEN_129")
        #expect(restored.screenshotSets.first?.assetIDs == [asset.id])

        var oldShape = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var oldAssets = try #require(oldShape["assets"] as? [[String: Any]])
        oldAssets[0].removeValue(forKey: "appStoreConnectScreenshotID")
        oldShape["assets"] = oldAssets
        var oldSets = try #require(oldShape["screenshotSets"] as? [[String: Any]])
        oldSets[0].removeValue(forKey: "appStoreConnectSetID")
        oldSets[0].removeValue(forKey: "appStoreConnectDisplayType")
        oldShape["screenshotSets"] = oldSets
        let decodedOld = try JSONDecoder().decode(AssetLibrary.self, from: JSONSerialization.data(withJSONObject: oldShape))
        #expect(decodedOld.assets.first?.appStoreConnectScreenshotID == nil)
        #expect(decodedOld.screenshotSets.first?.appStoreConnectSetID == nil)
    }

    @Test func appStoreConnectScreenshotImportDeduplicatesPerAppAndPreservesRemoteOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let app = AppRecord(name: "Screenshots", platforms: ["iOS"])
        let owner = AssetOwner(.app, app.id)
        let set = ScreenshotSet(appID: app.id, platform: .iPhone, categoryID: "iphone-island-large",
                                locale: "en-US", version: "2.0", name: "ASC",
                                appStoreConnectSetID: "remote-set", appStoreConnectDisplayType: "APP_IPHONE_67")
        let firstFile = root.appendingPathComponent("first.png")
        let secondFile = root.appendingPathComponent("second.png")
        let duplicateFile = root.appendingPathComponent("duplicate.png")
        try Data("first image bytes".utf8).write(to: firstFile)
        try Data("second image bytes".utf8).write(to: secondFile)
        try Data("replacement bytes must be ignored".utf8).write(to: duplicateFile)

        let first = try await store.importAsset(firstFile, owner: owner, displayName: "First",
            category: .marketing, appStoreConnectScreenshotID: "remote-one",
            remoteScreenshotOrder: ["remote-two", "remote-one"], remoteScreenshotSet: set)
        let second = try await store.importAsset(secondFile, owner: owner, displayName: "Second",
            category: .marketing, appStoreConnectScreenshotID: "remote-two",
            remoteScreenshotOrder: ["remote-two", "remote-one"], remoteScreenshotSet: set)
        let duplicate = try await store.importAsset(duplicateFile, owner: owner, displayName: "Changed Name",
            category: .marketing, appStoreConnectScreenshotID: "remote-one",
            remoteScreenshotOrder: ["remote-two", "remote-one"], remoteScreenshotSet: set)

        #expect(duplicate.id == first.id)
        let library = try await store.loadAssetLibrary().library
        #expect(library.assets.count == 2)
        #expect(library.screenshotSets.first?.assetIDs == [second.id, first.id])
        let storedFirst = try await store.resolveContentMedia(first.reference, recordFolder: "")
        #expect(try Data(contentsOf: storedFirst) == Data("first image bytes".utf8))

        let otherApp = AssetOwner(.app, "another-local-app")
        var otherSet = set
        otherSet.id = UUID()
        otherSet.appID = otherApp.id
        otherSet.appStoreConnectSetID = "other-remote-set"
        let scoped = try await store.importAsset(duplicateFile, owner: otherApp, displayName: "Other App",
            category: .marketing, appStoreConnectScreenshotID: "remote-one",
            remoteScreenshotOrder: ["remote-one"], remoteScreenshotSet: otherSet)
        #expect(scoped.id != first.id)
        #expect(try await store.loadAssetLibrary().library.assets.count == 3)
    }

    @Test func appStoreScreenshotResponseDecodesNestedSetsAndSafeCDNPreviews() throws {
        let json = #"""
        {"localizations":[{"locale":"en-US","sets":[{"set":{"id":"remote-set","attributes":{"displayType":"APP_IPHONE_67"}},"screenshots":[{"id":"remote-shot","attributes":{"fileName":"home.png","imageAsset":{"templateUrl":"https://is1-ssl.mzstatic.com/image/thumb/a/{w}x{h}bb.{f}","width":2880,"height":1800}}}]}]}]}
        """#
        let version = ASCVersion(id: "remote-version", attributes: .init(
            versionString: "3.2", platform: "IOS", appVersionState: nil, appStoreState: nil,
            createdDate: nil, earliestReleaseDate: nil
        ))
        let collections = try RemoteScreenshotCollection.decode(Data(json.utf8), version: version)
        #expect(collections.count == 1)
        #expect(collections[0].remoteSetID == "remote-set")
        #expect(collections[0].locale == "en-US")
        #expect(collections[0].displayType == "APP_IPHONE_67")
        #expect(collections[0].categoryID == "iphone-island-large")
        #expect(collections[0].screenshots.first?.id == "remote-shot")
        #expect(collections[0].screenshots.first?.filename == "home.png")
        #expect(collections[0].screenshots.first?.previewURL?.host == "is1-ssl.mzstatic.com")
        #expect(collections[0].screenshots.first?.previewURL?.absoluteString.contains("420x263bb.jpg") == true)
    }

    @Test func importOrganizationAndReferencesSurviveRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let app = AppRecord(name: "Universal App", platforms: ["iOS", "iPadOS", "macOS"])
        _ = try await store.save(app, relativePath: "Apps/test-app/record.json")
        let owner = AssetOwner(.app, app.id)
        var library = AssetLibrary()
        let parent = AssetFolder(name: "Launch", owner: owner)
        let child = AssetFolder(name: "Graphics", owner: owner, parentID: parent.id)
        library.folders = [parent, child]
        let firstSet = ScreenshotSet(appID: app.id, platform: .mac, categoryID: "mac", locale: "en-US", version: "1.0", name: "")
        let secondSet = ScreenshotSet(appID: app.id, platform: .mac, categoryID: "mac", locale: "fr-FR", version: "1.0", name: "")
        library.screenshotSets = [firstSet, secondSet]
        _ = try await store.saveAssetLibrary(library, revision: nil)

        let sourceA = root.appendingPathComponent("A/screenshot.png")
        let sourceB = root.appendingPathComponent("B/screenshot.png")
        for source in [sourceA, sourceB] {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeImage(to: source, width: 1280, height: 800)
        }
        let a = try await store.importAsset(sourceA, owner: owner, folderID: child.id, into: firstSet.id)
        let b = try await store.importAsset(sourceB, owner: owner, into: firstSet.id)
        let fileA = try await store.resolveContentMedia(a.reference, recordFolder: "")
        let fileB = try await store.resolveContentMedia(b.reference, recordFolder: "")
        #expect(a.name == b.name)
        #expect(fileA != fileB)
        #expect(FileManager.default.fileExists(atPath: sourceA.path))
        let reused = try await store.importAsset(fileA, owner: .shared)
        #expect(reused.id == a.id)
        #expect(try await store.loadAssetLibrary().library.assets.count == 2)

        var post = ContentRecord.draft(kind: .social, title: "Launch Post")
        post.appIds = [app.id]
        post.mediaPaths = [a.reference, b.reference]
        _ = try await store.createContent(post, body: "Hello")

        let loaded = try await store.loadAssetLibrary()
        library = loaded.library
        library.assets[0].name = "Renamed Screenshot"
        library.assets[0].tags = ["Launch", "Approved"]
        library.assets[0].folderID = parent.id
        library.screenshotSets[0].assetIDs.reverse()
        library.screenshotSets[1].assetIDs = [a.id, b.id]
        _ = try await store.saveAssetLibrary(library, revision: loaded.revision)

        let reopened = WorkspaceStore(rootURL: root)
        let restored = try await reopened.loadAssetLibrary().library
        #expect(restored.folders.first { $0.id == child.id }?.parentID == parent.id)
        #expect(restored.assets.first?.owner == owner)
        #expect(restored.assets.first?.folderID == parent.id)
        #expect(restored.assets.first?.tags == ["Launch", "Approved"])
        #expect(restored.screenshotSets[0].assetIDs == [b.id, a.id])
        #expect(restored.screenshotSets[1].assetIDs == [a.id, b.id])
        #expect(try await reopened.resolveContentMedia(a.reference, recordFolder: "Content/\(post.id)") == fileA)
        #expect(try await reopened.load().contentByID[post.id]?.mediaPaths == [a.reference, b.reference])
        let checks = await reopened.validateScreenshotSets(restored)
        #expect(checks[firstSet.id]?.ready == true)
        #expect(checks[secondSet.id]?.ready == true)
        #expect(try await reopened.validateWorkspace().isEmpty)
        do {
            try await reopened.trashAsset(a.id)
            Issue.record("A referenced asset must remain available")
        } catch {
            #expect(FileManager.default.fileExists(atPath: fileA.path))
        }

        let latest = try await reopened.loadAssetLibrary()
        library = latest.library
        library.removeFolder(parent.id)
        library.screenshotSets.removeAll()
        _ = try await reopened.saveAssetLibrary(library, revision: latest.revision)
        let unfiled = try await reopened.loadAssetLibrary().library
        #expect(unfiled.assets.first?.folderID == nil)
        #expect(unfiled.folders.count == 1)
        #expect(unfiled.folders.first?.parentID == nil)
        #expect(FileManager.default.fileExists(atPath: fileA.path))
        do {
            try await reopened.trashAsset(a.id)
            Issue.record("Saved post references must protect the file after removing screenshot sets")
        } catch {
            #expect(FileManager.default.fileExists(atPath: fileA.path))
        }
    }

    @Test func exactDimensionsFileFormatTransparencyAndCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mac.png")
        try writeImage(to: file, width: 1440, height: 900)
        let mac = try #require(ScreenshotSpecifications.category("mac"))
        let tv = try #require(ScreenshotSpecifications.category("tv"))
        #expect(mac.issues(for: file).isEmpty)
        #expect(tv.issues(for: file).contains { $0.contains("1920 × 1080") })
        let alpha = root.appendingPathComponent("alpha.png")
        try writeImage(to: alpha, width: 1440, height: 900, alpha: true)
        #expect(mac.issues(for: alpha).contains { $0.contains("alpha channel") })
        let opaqueAlpha = root.appendingPathComponent("opaque-alpha.png")
        try writeImage(to: opaqueAlpha, width: 1440, height: 900, alpha: true, opacity: 1)
        #expect(mac.issues(for: opaqueAlpha).contains { $0.contains("alpha channel") })
        let rotated = root.appendingPathComponent("vertical.png")
        try writeImage(to: rotated, width: 900, height: 1440)
        #expect(!mac.issues(for: rotated).isEmpty)
        let renamed = root.appendingPathComponent("renamed.jpg")
        try FileManager.default.copyItem(at: file, to: renamed)
        #expect(mac.issues(for: renamed).contains { $0.contains("JPEG") })
        #expect(!mac.issues(for: nil).isEmpty)

        #expect(ScreenshotSpecifications.all.count == 24)
        #expect(ScreenshotPlatform.supported(by: ["iOS", "iPadOS", "Mac"]) == [.iPhone, .iPad, .mac])
        #expect(ScreenshotSpecifications.requiredCategories(for: .iPad, available: []) == ["ipad-13"])
        #expect(ScreenshotSpecifications.scalingSource(for: "ipad-9.7", available: ["ipad-13"])?.id == "ipad-13")
        #expect(ScreenshotSpecifications.scalingSource(for: "iphone-face-large", available: []) == nil)
        #expect(ScreenshotSpecifications.scalingSource(for: "iphone-island-medium", available: ["iphone-island-large"])?.id == "iphone-island-large")
        #expect(ScreenshotSpecifications.scalingSource(for: "iphone-duo-inner", available: ["iphone-island-large"]) == nil)
        #expect(AssetLibrary.managedPath("asset:../../outside.png") == nil)
    }

    @Test func watchSizesAndScreenshotCountAreCheckedAcrossSets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceStore(rootURL: root)
        try await store.createWorkspace(at: root)
        let first = root.appendingPathComponent("ultra.png")
        let second = root.appendingPathComponent("series.png")
        try writeImage(to: first, width: 422, height: 514)
        try writeImage(to: second, width: 416, height: 496)
        let a = try await store.importAsset(first, owner: .shared)
        let b = try await store.importAsset(second, owner: .shared)
        let en = ScreenshotSet(appID: "app", platform: .watch, categoryID: "watch-ultra-4-3", locale: "en-US", version: "", name: "", assetIDs: [a.id])
        let es = ScreenshotSet(appID: "app", platform: .watch, categoryID: "watch-series-12-10", locale: "es-ES", version: "", name: "", assetIDs: [b.id])
        let empty = ScreenshotSet(appID: "app", platform: .mac, categoryID: "mac", locale: "en-US", version: "", name: "")
        let loaded = try await store.loadAssetLibrary()
        var library = loaded.library
        var tooMany = empty
        tooMany.id = UUID()
        tooMany.assetIDs = (0...10).map { _ in UUID() }
        library.screenshotSets = [en, es, empty, tooMany]
        let checks = await store.validateScreenshotSets(library)
        #expect(checks[en.id]?.summary.first?.contains("localizations") == true)
        #expect(checks[es.id]?.ready == false)
        #expect(checks[empty.id]?.summary.first?.contains("1–10") == true)
        #expect(checks[tooMany.id]?.summary.first?.contains("1–10") == true)
    }

    private func writeImage(to url: URL, width: Int, height: Int, alpha: Bool = false, opacity: CGFloat = 0.5) throws {
        let bitmap = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? opacity : 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
    }
}
