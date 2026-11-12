import CryptoKit
import Foundation
import ImageIO
import Security
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ImageHosting: Codable, Sendable {
    var accountID = ""
    var bucket = ""
    var accessKeyID = ""
    var secretAccessKey = ""

    private static var keychainItem: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.bravenewdesign.indiedevbuddy.image-hosting",
         kSecAttrAccount as String: "r2"]
    }

    static func load() throws -> Self? {
        var query = keychainItem
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func save() throws {
        guard accountID.wholeMatch(of: /[a-f0-9]{32}/) != nil,
              bucket.wholeMatch(of: /[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/) != nil,
              accessKeyID.wholeMatch(of: /[A-Za-z0-9]+/) != nil,
              !secretAccessKey.isEmpty else { throw Failure.configuration }
        let attributes = [kSecValueData as String: try JSONEncoder().encode(self)]
        let status = SecItemUpdate(Self.keychainItem as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = Self.keychainItem.merging(attributes) { _, new in new }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.keychain }
        } else if status != errSecSuccess {
            throw Failure.keychain
        }
    }

    static func remove() throws {
        let status = SecItemDelete(keychainItem as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain }
    }

    func uploadImage(at file: URL) async throws -> URL {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1440
              ] as CFDictionary) else { throw Failure.image }
        let jpeg = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure.image
        }
        CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(encoder) else { throw Failure.image }

        let path = "/\(bucket)/indie-dev-buddy/\(UUID().uuidString.lowercased()).jpg"
        var request = URLRequest(url: try signedURL(method: "PUT", path: path, seconds: 300))
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.upload(for: request, from: jpeg as Data)
        } catch {
            try Task.checkCancellation()
            throw Failure.upload
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.upload
        }
        return try signedURL(method: "GET", path: path, seconds: 3600)
    }

    private func signedURL(method: String, path: String, seconds: Int) throws -> URL {
        let host = "\(accountID).r2.cloudflarestorage.com"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: .now)
        let day = String(timestamp.prefix(8))
        let scope = "\(day)/auto/s3/aws4_request"
        let query = "X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=\(accessKeyID)%2F\(day)%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=\(timestamp)&X-Amz-Expires=\(seconds)&X-Amz-SignedHeaders=host"
        let canonical = "\(method)\n\(path)\n\(query)\nhost:\(host)\n\nhost\nUNSIGNED-PAYLOAD"
        let digest = Self.hex(SHA256.hash(data: Data(canonical.utf8)))
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(digest)"
        let signingKey = [day, "auto", "s3", "aws4_request"].reduce(Data("AWS4\(secretAccessKey)".utf8)) { key, value in
            Self.hmac(value, key: key)
        }
        let signature = Self.hex(Self.hmac(stringToSign, key: signingKey))
        guard let url = URL(string: "https://\(host)\(path)?\(query)&X-Amz-Signature=\(signature)") else {
            throw Failure.configuration
        }
        return url
    }

    private static func hmac(_ value: String, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", Int($0)) }.joined()
    }

    enum Failure: LocalizedError {
        case keychain, configuration, image, upload

        var errorDescription: String? {
            switch self {
            case .keychain: "Image hosting credentials could not be accessed in Keychain."
            case .configuration: "Enter a Cloudflare account ID, bucket name, and S3 access keys in Image Hosting settings."
            case .image: "The attachment could not be converted to a JPEG."
            case .upload: "The image could not be uploaded. Check your connection and the bucket’s Object Read & Write permissions."
            }
        }
    }
}

struct ImageHostingSettings: View {
    @State private var settings = ImageHosting()
    @State private var connected = false
    @State private var message: String?

    var body: some View {
        Section("Image Hosting") {
            Text("Connect your own Cloudflare R2 bucket to publish a local image to Instagram or Threads using Publish Now. Storage usage is billed to your Cloudflare account.")
            TextField("Cloudflare account ID", text: $settings.accountID)
            TextField("Bucket name", text: $settings.bucket)
            SecureField("S3 access key ID", text: $settings.accessKeyID)
            SecureField("S3 secret access key", text: $settings.secretAccessKey)
            Text("Use a bucket-scoped Object Read & Write token. Set a lifecycle rule to delete objects under indie-dev-buddy/ after one day.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Save R2 Settings") {
                    update {
                        try settings.save()
                        connected = true
                        settings.secretAccessKey = ""
                        message = "Saved to Keychain. The connection is used when you publish."
                    }
                }
                if connected {
                    Button("Disconnect", role: .destructive) {
                        update {
                            try ImageHosting.remove()
                            settings = ImageHosting()
                            connected = false
                            message = nil
                        }
                    }
                }
            }
            if let message { Text(message).font(.caption) }
        }
        .onAppear {
            update {
                if var saved = try ImageHosting.load() {
                    saved.secretAccessKey = ""
                    settings = saved
                    connected = true
                }
            }
        }
    }

    private func update(_ action: () throws -> Void) {
        do { try action() }
        catch { message = error.localizedDescription }
    }
}
