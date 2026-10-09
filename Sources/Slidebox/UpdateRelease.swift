import Foundation
import CryptoKit

struct ReleaseVersion: Comparable {
    private let numbers: [Int]
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  part.count == 1 || part.first != "0", let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
}

struct UpdateRelease: Codable {
    static let repository = "yuan-me/slidebox"
    static let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let maximumSize: Int64 = 100 * 1024 * 1024
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    struct Asset: Codable, Equatable {
        let name: String
        let size: Int64
        let digest: String?
        let browser_download_url: URL

        func verify(_ file: URL) throws {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256(), count: Int64 = 0
            while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                count += Int64(bytes.count)
                guard count <= size else { throw UpdateError.invalidDownload }
                hash.update(data: bytes)
            }
            let actual = "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == size, actual == digest else { throw UpdateError.invalidDownload }
        }
    }

    func newerAsset(than current: String) throws -> Asset? {
        guard !draft, !prerelease else { return nil }
        guard let version = ReleaseVersion(tag_name), let installed = ReleaseVersion(current) else { throw UpdateError.invalidRelease }
        guard version > installed else { return nil }
        let name = "Slidebox-\(tag_name)-macos-universal.zip"
        let expected = "https://github.com/\(Self.repository)/releases/download/\(tag_name)/\(name)"
        guard let asset = assets.first(where: { $0.name == name }),
              asset.size > 0, asset.size <= Self.maximumSize,
              asset.browser_download_url.absoluteString == expected,
              let digest = asset.digest, digest.hasPrefix("sha256:"), digest.count == 71,
              digest.dropFirst(7).allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }) else {
            throw UpdateError.invalidRelease
        }
        return asset
    }
}

enum UpdateError: LocalizedError {
    case invalidRelease, invalidDownload
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .http(let status): return status == 403 || status == 429 ? "GitHub 请求暂时受限，请稍后重试。" : "检查更新失败（HTTP \(status)）。"
        case .invalidRelease: return "发行信息或安装包不完整，请稍后重试。"
        case .invalidDownload: return "下载文件校验失败，请重新下载。"
        }
    }
}

func runUpdateChecks() throws {
    let now = Date()
    precondition(AppUpdates.isDue(last: nil, now: now))
    precondition(!AppUpdates.isDue(last: now.addingTimeInterval(-86399), now: now))
    precondition(AppUpdates.isDue(last: now.addingTimeInterval(-86400), now: now))
    precondition(AppUpdates.isDue(last: now.addingTimeInterval(3600), now: now))
    precondition(ReleaseVersion("v1.0.0") == ReleaseVersion("1.0.0"))
    precondition(ReleaseVersion("1.10.0")! > ReleaseVersion("1.9.9")!)
    precondition(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!)
    for invalid in ["", "1.0", "01.0.0", "1.0.0-beta.1", "1.-1.0", "1.0.0.0", "1.0.9999999999999999999999999"] {
        precondition(ReleaseVersion(invalid) == nil)
    }
    let bytes = Data("verified update fixture".utf8)
    let digest = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let name = "Slidebox-v1.1.0-macos-universal.zip"
    let url = URL(string: "https://github.com/yuan-me/slidebox/releases/download/v1.1.0/\(name)")!
    let asset = UpdateRelease.Asset(name: name, size: Int64(bytes.count), digest: digest, browser_download_url: url)
    let release = UpdateRelease(tag_name: "v1.1.0", draft: false, prerelease: false, assets: [asset])
    let newer = try release.newerAsset(than: "1.0.0")
    let equal = try release.newerAsset(than: "1.1.0")
    let older = try release.newerAsset(than: "2.0.0")
    precondition(newer == asset && equal == nil && older == nil)
    for hidden in [UpdateRelease(tag_name: "v1.1.0", draft: true, prerelease: false, assets: [asset]),
                   UpdateRelease(tag_name: "v1.1.0-beta", draft: false, prerelease: true, assets: [asset])] {
        let hiddenAsset = try hidden.newerAsset(than: "1.0.0")
        precondition(hiddenAsset == nil)
    }
    for bad in [UpdateRelease.Asset(name: name, size: 0, digest: digest, browser_download_url: url),
                UpdateRelease.Asset(name: name, size: asset.size, digest: nil, browser_download_url: url),
                UpdateRelease.Asset(name: name, size: asset.size, digest: digest, browser_download_url: URL(string: "https://example.com/update.zip")!),
                UpdateRelease.Asset(name: name, size: UpdateRelease.maximumSize + 1, digest: digest, browser_download_url: url)] {
        do {
            _ = try UpdateRelease(tag_name: "v1.1.0", draft: false, prerelease: false, assets: [bad]).newerAsset(than: "1.0.0")
            preconditionFailure("Accepted invalid release asset")
        } catch UpdateError.invalidRelease {}
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try bytes.write(to: file); try asset.verify(file)
    try Data(repeating: 0, count: bytes.count).write(to: file)
    do { try asset.verify(file); preconditionFailure("Accepted tampered download") } catch UpdateError.invalidDownload {}
    print("PASS: release version order, stable releases, asset URL/size, SHA-256 and tampering")
}
