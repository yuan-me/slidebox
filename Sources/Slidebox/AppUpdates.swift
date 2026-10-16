import AppKit

@MainActor
final class AppUpdates {
    nonisolated static let interval: TimeInterval = 86400
    let version: String
    var changed: (() -> Void)?
    private(set) var busy = false
    private(set) var message: String
    private(set) var downloadedURL: URL?
    private let defaults: UserDefaults
    private let directory: URL
    private let transport = UpdateTransport()
    private var task: Task<Void, Never>?
    private var timer: Timer?

    var enabled: Bool { defaults.object(forKey: "automaticUpdates") as? Bool ?? true }

    init(defaults: UserDefaults = .standard,
         directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Slidebox/Updates", isDirectory: true),
         version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1") {
        self.defaults = defaults; self.directory = directory; self.version = version
        message = "当前版本 \(version)"
    }

    nonisolated static func isDue(last: Date?, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval || last > now
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: "automaticUpdates")
        if value { check() }
        else {
            timer?.invalidate(); timer = nil; task?.cancel()
            message = "已关闭自动检查与下载"; changed?()
        }
    }

    func stop() { timer?.invalidate(); timer = nil; task?.cancel() }

    func check(manual: Bool = false) {
        guard !busy, manual || enabled else { return }
        let fetch = manual || Self.isDue(last: defaults.object(forKey: "updateLastAttempt") as? Date)
        if !fetch && defaults.data(forKey: "updateRelease") == nil { schedule(); return }
        busy = true; message = fetch ? "正在检查更新…" : "正在验证已下载版本…"; changed?()
        timer?.invalidate(); timer = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.changed?(); self.schedule() }
            do {
                let release: UpdateRelease?
                if fetch {
                    self.defaults.set(Date(), forKey: "updateLastAttempt")
                    release = try await self.transport.latest()
                    try Task.checkCancellation()
                    if let release { self.defaults.set(try JSONEncoder().encode(release), forKey: "updateRelease") }
                    else { self.defaults.removeObject(forKey: "updateRelease") }
                } else {
                    release = try JSONDecoder().decode(UpdateRelease.self, from: self.defaults.data(forKey: "updateRelease")!)
                }
                guard let release, let asset = try release.newerAsset(than: self.version) else {
                    self.downloadedURL = nil; self.message = "当前已是最新正式版（\(self.version)）"; return
                }
                self.message = "正在下载 \(release.tag_name)…"; self.changed?()
                let destination = self.directory.appendingPathComponent(asset.name)
                try await self.transport.prepare(asset, in: self.directory)
                try Task.checkCancellation()
                self.downloadedURL = destination
                self.message = "\(release.tag_name) 已下载并校验，解压后手动替换应用。"
            } catch {
                if Task.isCancelled { self.message = self.enabled ? "更新已取消" : "已关闭自动检查与下载" }
                else { self.message = error.localizedDescription }
            }
        }
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard enabled else { return }
        let last = defaults.object(forKey: "updateLastAttempt") as? Date ?? Date()
        let delay = max(60, min(Self.interval, last.addingTimeInterval(Self.interval).timeIntervalSinceNow))
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = min(3600, delay / 10)
    }
}
