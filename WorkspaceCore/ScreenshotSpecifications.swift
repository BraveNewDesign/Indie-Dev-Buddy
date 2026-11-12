import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated public enum ScreenshotPlatform: String, Codable, CaseIterable, Sendable {
    case iPhone = "iOS"
    case iPad = "iPadOS"
    case mac = "macOS"
    case watch = "watchOS"
    case tv = "tvOS"
    case vision = "visionOS"

    public static func supported(by declarations: [String]) -> [Self] {
        let names = Set(declarations.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        return allCases.filter { platform in
            if names.contains(platform.rawValue.lowercased()) { return true }
            switch platform {
            case .iPhone: return names.contains("iphone")
            case .iPad: return names.contains("ipad")
            case .mac: return names.contains("mac")
            case .watch: return names.contains("apple watch")
            case .tv: return names.contains("apple tv")
            case .vision: return names.contains("apple vision pro")
            }
        }
    }
}

nonisolated public struct ScreenshotPixels: Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width) × \(height)" }
}

nonisolated public struct ScreenshotSpecification: Identifiable, Sendable {
    public let id: String
    public let platform: ScreenshotPlatform
    public let title: String
    public let sizes: [ScreenshotPixels]
    public let scaledFrom: String?

    public func issues(for url: URL?) -> [String] {
        guard let url, FileManager.default.isReadableFile(atPath: url.path) else {
            return ["The original file is missing or unavailable."]
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(source) as String?,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              CGImageSourceGetStatusAtIndex(source, 0).rawValue == 0 else {
            return ["This file is not a readable screenshot."]
        }

        var issues: [String] = []
        let ext = url.pathExtension.lowercased()
        if !((type == UTType.jpeg.identifier && ["jpg", "jpeg"].contains(ext)) ||
             (type == UTType.png.identifier && ext == "png")) {
            issues.append("Use a JPEG (.jpg or .jpeg) or PNG image.")
        }
        if properties[kCGImagePropertyHasAlpha] as? Bool == true {
            issues.append("Export without an alpha channel or transparency.")
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let pixels = [5, 6, 7, 8].contains(orientation)
            ? ScreenshotPixels(height, width) : ScreenshotPixels(width, height)
        if !sizes.contains(pixels) {
            issues.append("\(pixels) px. Accepted sizes: \(sizes.map(\.description).joined(separator: ", ")) px.")
        }
        return issues
    }
}

// Apple App Store Connect Help, Screenshot specifications, verified 2026-11-12.
// https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
nonisolated public enum ScreenshotSpecifications {
    public static let count = 1...10

    public static let all: [ScreenshotSpecification] = [
        spec("iphone-island-large", .iPhone, "iPhone with Dynamic Island (large display)", rotated([(1260, 2736), (1290, 2796), (1320, 2868)]), from: "iphone-face-large"),
        spec("iphone-island-medium", .iPhone, "iPhone with Dynamic Island (medium display)", rotated([(1179, 2556), (1206, 2622)]), from: "iphone-face-large"),
        spec("iphone-face-large", .iPhone, "iPhone with Face ID (large display)", rotated([(1284, 2778), (1242, 2688)]), from: "iphone-island-large"),
        spec("iphone-face-medium", .iPhone, "iPhone with Face ID (medium display)", rotated([(1170, 2532), (1125, 2436), (1080, 2340)]), from: "iphone-island-medium"),
        spec("iphone-home-large", .iPhone, "iPhone with Home Button (large display)", rotated([(1242, 2208)]), from: "iphone-face-medium"),
        spec("iphone-home-medium", .iPhone, "iPhone with Home Button (medium display)", rotated([(750, 1334)]), from: "iphone-home-large"),
        spec("iphone-home-4", .iPhone, "iPhone with Home Button (4″ display)", [(640, 1096), (640, 1136), (1136, 600), (1136, 640)], from: "iphone-home-medium"),
        spec("iphone-home-3.5", .iPhone, "iPhone with Home Button (3.5″ display)", [(640, 920), (640, 960), (960, 600), (960, 640)], from: "iphone-home-4"),
        spec("iphone-duo-outer", .iPhone, "iPhone Duo (outer display)", rotated([(1398, 2034)])),
        spec("iphone-duo-inner", .iPhone, "iPhone Duo (inner display)", rotated([(2007, 2853)])),
        spec("ipad-13", .iPad, "13″ display", rotated([(2064, 2752), (2048, 2732)])),
        spec("ipad-12.9", .iPad, "12.9″ display", rotated([(2048, 2732)]), from: "ipad-13"),
        spec("ipad-11", .iPad, "11″ display", rotated([(1488, 2266), (1512, 2316), (1668, 2420), (1668, 2388), (1640, 2360)]), from: "ipad-13"),
        spec("ipad-10.5", .iPad, "10.5″ display", rotated([(1668, 2224)]), from: "ipad-12.9"),
        spec("ipad-9.7", .iPad, "9.7″ display", [(1536, 2008), (1536, 2048), (2048, 1496), (2048, 1536), (768, 1004), (768, 1024), (1024, 748), (1024, 768)], from: "ipad-10.5"),
        spec("mac", .mac, "Mac", [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]),
        spec("watch-ultra-4-3", .watch, "Apple Watch (Ultra 4, Ultra 3)", [(422, 514)]),
        spec("watch-ultra-2-1", .watch, "Apple Watch (Ultra 2, Ultra)", [(410, 502)]),
        spec("watch-series-12-10", .watch, "Apple Watch (Series 12, 11, 10)", [(416, 496)]),
        spec("watch-series-9-7", .watch, "Apple Watch (Series 9, 8, 7)", [(396, 484)]),
        spec("watch-series-6-4-se", .watch, "Apple Watch (Series 6, 5, 4, SE 3, SE 2, SE)", [(368, 448)]),
        spec("watch-series-3-1", .watch, "Apple Watch (Series 3, 2, 1)", [(312, 390)]),
        spec("tv", .tv, "Apple TV", [(1920, 1080), (3840, 2160)]),
        spec("vision", .vision, "Apple Vision Pro", [(3840, 2160)])
    ]

    public static func dimensions(of url: URL) -> ScreenshotPixels? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return [5, 6, 7, 8].contains(orientation) ? ScreenshotPixels(height, width) : ScreenshotPixels(width, height)
    }

    public static func category(_ id: String) -> ScreenshotSpecification? {
        all.first { $0.id == id }
    }

    public static func scalingSource(for categoryID: String, available: Set<String>) -> ScreenshotSpecification? {
        var visited = Set([categoryID])
        var candidate = category(categoryID)?.scaledFrom
        while let id = candidate, visited.insert(id).inserted {
            if available.contains(id) { return category(id) }
            candidate = category(id)?.scaledFrom
        }
        return nil
    }

    /// Apple's iPhone table additionally requires Face ID (large) if the large
    /// Dynamic Island set is omitted. The overview separately lists medium.
    public static func requiredCategories(for platform: ScreenshotPlatform, available: Set<String>) -> [String] {
        switch platform {
        case .iPhone:
            return ["iphone-island-medium", available.contains("iphone-island-large") ? "iphone-island-large" : "iphone-face-large"]
        case .iPad: return ["ipad-13"]
        case .mac: return ["mac"]
        case .watch:
            let watchCategories = all.filter { $0.platform == .watch }
            return [watchCategories.first(where: { available.contains($0.id) })?.id ?? watchCategories[0].id]
        case .tv: return ["tv"]
        case .vision: return ["vision"]
        }
    }

    public static let iPhoneDuoRequirement = "Apple lists iPhone Duo screenshots as required starting April 2027 for apps using the iOS 27.1 SDK or later."

    private static func rotated(_ sizes: [(Int, Int)]) -> [(Int, Int)] {
        sizes.flatMap { width, height in [(width, height), (height, width)] }
    }

    private static func spec(_ id: String, _ platform: ScreenshotPlatform, _ title: String,
                             _ sizes: [(Int, Int)], from source: String? = nil) -> ScreenshotSpecification {
        ScreenshotSpecification(id: id, platform: platform, title: title,
                                sizes: sizes.map { ScreenshotPixels($0.0, $0.1) }, scaledFrom: source)
    }
}
