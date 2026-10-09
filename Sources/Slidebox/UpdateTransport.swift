import Foundation

/// Network transfers and file hashing stay off the UI actor.
actor UpdateTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["User-Agent": "Slidebox", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        return URLSession(configuration: configuration)
    }()

    func latest() async throws -> UpdateRelease? {
        let (bytes, response) = try await session.bytes(from: UpdateRelease.endpoint)
        guard let response = response as? HTTPURLResponse else { throw UpdateError.invalidRelease }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw UpdateError.http(response.statusCode) }
        guard response.expectedContentLength <= 1024 * 1024 else { throw UpdateError.invalidRelease }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            guard data.count <= 1024 * 1024 else { throw UpdateError.invalidRelease }
        }
        return try JSONDecoder().decode(UpdateRelease.self, from: data)
    }

    func prepare(_ asset: UpdateRelease.Asset, in directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(asset.name)
        if (try? asset.verify(destination)) == nil { try await download(asset, to: destination) }
        // This directory is app-owned and contains only downloaded release ZIPs.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file != destination && file.lastPathComponent.hasPrefix("Slidebox-") && file.pathExtension == "zip" {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func download(_ asset: UpdateRelease.Asset, to destination: URL) async throws {
        let (file, response) = try await session.download(from: asset.browser_download_url, delegate: DownloadLimit(size: asset.size))
        defer { try? FileManager.default.removeItem(at: file) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw UpdateError.invalidDownload }
        try asset.verify(file)
        try Task.checkCancellation()
        // Copy only after validation; never destroy an existing file on a failed transfer.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: file, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }
}

private final class DownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let size: Int64
    init(size: Int64) { self.size = size }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size || totalBytesExpectedToWrite > size { downloadTask.cancel() }
    }
}

@MainActor
func runUpdateNetworkChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "local.slidebox.update-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let updates = AppUpdates(defaults: defaults, directory: directory, version: "0.0.0")
    defer {
        updates.stop(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    updates.setEnabled(false); updates.check()
    precondition(!updates.busy && defaults.object(forKey: "updateLastAttempt") == nil)
    updates.check(manual: true)
    let deadline = Date().addingTimeInterval(90)
    while updates.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    guard let file = updates.downloadedURL, !updates.busy else {
        throw NSError(domain: "UpdateCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: updates.message])
    }
    let release = try JSONDecoder().decode(UpdateRelease.self, from: defaults.data(forKey: "updateRelease")!)
    guard let asset = try release.newerAsset(than: "0.0.0") else { throw UpdateError.invalidRelease }
    try asset.verify(file)
    let lastAttempt = defaults.object(forKey: "updateLastAttempt") as! Date
    let modified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
    updates.setEnabled(true)
    while updates.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    precondition(!updates.busy && updates.downloadedURL == file)
    precondition(defaults.object(forKey: "updateLastAttempt") as? Date == lastAttempt)
    let reused = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
    precondition(modified == reused, "A verified cached release was downloaded again")
    print("PASS: automatic update flow, manual override, 24h throttle, cached ZIP reuse and SHA-256: \(asset.name)")
}
