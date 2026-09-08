import AppKit
import CryptoKit
import ImageIO
import WebKit

@MainActor
final class SiteIcons {
    static let shared = SiteIcons()
    var changed: (() -> Void)?
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 100; return cache
    }()
    private var attempted: [String: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Slidebox/Icons", isDirectory: true)

    static func key(_ url: URL) -> String? {
        guard let url = websiteURL(url.absoluteString), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        return parts.url?.absoluteString
    }

    private func file(_ key: String) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png")
    }

    func image(for url: URL) -> NSImage? {
        guard let key = Self.key(url) else { return nil }
        if let image = images.object(forKey: key as NSString) { return image }
        guard let image = NSImage(contentsOf: file(key)) else { return nil }
        images.setObject(image, forKey: key as NSString)
        return image
    }

    func discover(in view: WKWebView) {
        guard let url = view.url, let key = Self.key(url) else { return }
        if let date = attempted[key], Date().timeIntervalSince(date) < 3600 { return }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file(key).path),
           let date = attributes[.modificationDate] as? Date, Date().timeIntervalSince(date) < 604800 { return }
        attempted[key] = Date()
        view.evaluateJavaScript("Array.from(document.querySelectorAll('link[rel]')).filter(l => /^(icon|shortcut icon|apple-touch-icon)$/i.test(l.rel.trim())).map(l => l.href)") { [weak self] result, _ in
            guard let self else { return }
            let candidates = (result as? [String] ?? []).compactMap(websiteURL)
            Task { await self.fetch(Array(candidates.prefix(5)) + [URL(string: key + "/favicon.ico")!], key: key) }
        }
    }

    private func fetch(_ urls: [URL], key: String) async {
        for url in urls {
            do {
                let (bytes, response) = try await session.bytes(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.expectedContentLength <= 524288 else { continue }
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 524288 { break }
                }
                guard data.count <= 524288, let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 64
                      ] as CFDictionary),
                      let png = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]),
                      let image = NSImage(data: png) else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: file(key), options: .atomic)
                images.setObject(image, forKey: key as NSString)
                changed?()
                return
            } catch { continue }
        }
    }
}
