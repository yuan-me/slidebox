import Foundation

struct Site: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: URL
}

func reorderedSites(_ sites: [Site], source: UUID, target: UUID) -> [Site] {
    guard let from = sites.firstIndex(where: { $0.id == source }), let to = sites.firstIndex(where: { $0.id == target }), from != to else { return sites }
    var result = sites
    result.insert(result.remove(at: from), at: to)
    return result
}

struct Preferences: Codable, Equatable {
    var width: Double = 480
    var height: Double = 680
    var pinned = false
    var sleepEnabled = true
    var sleepSeconds = 30
    init() {}
    private enum CodingKeys: String, CodingKey { case width, height, pinned, sleepEnabled, sleepSeconds }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 480
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 680
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        sleepEnabled = try values.decodeIfPresent(Bool.self, forKey: .sleepEnabled) ?? true
        sleepSeconds = max(1, min(86400, try values.decodeIfPresent(Int.self, forKey: .sleepSeconds) ?? 30))
    }
}

func websiteURL(_ input: String) -> URL? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }) else { return nil }
    let candidate = text.contains("://") ? text : "https://" + text
    guard let parts = URLComponents(string: candidate),
          ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
          let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil,
          let url = parts.url else { return nil }
    // Bare words are not search queries. Localhost and explicit IPs remain useful.
    guard text.contains("://") || host.contains(".") || host == "localhost" || host.contains(":") else { return nil }
    if let port = parts.port, !(1...65535).contains(port) { return nil }
    return url
}

/// A single deadline per inactive page. ContinuousClock also accounts for sleep.
struct Retention {
    var deadlines: [UUID: ContinuousClock.Instant] = [:]
    var delay: Int? = 30
    mutating func suspend(_ id: UUID, at now: ContinuousClock.Instant) {
        guard let delay else { return }
        if deadlines[id] == nil { deadlines[id] = now.advanced(by: .seconds(delay)) }
    }
    mutating func activate(_ id: UUID) { deadlines.removeValue(forKey: id) }
    func expired(at now: ContinuousClock.Instant) -> [UUID] {
        deadlines.compactMap { $0.value <= now ? $0.key : nil }
    }
    var next: ContinuousClock.Instant? { deadlines.values.min() }
}

@MainActor
final class Store {
    private let defaults: UserDefaults
    var sites: [Site] { didSet { if sites != oldValue { save(sites, key: "sites") } } }
    var preferences: Preferences { didSet { if preferences != oldValue { save(preferences, key: "preferences") } } }
    var selected: UUID? {
        didSet { if selected != oldValue { defaults.set(selected?.uuidString, forKey: "selected") } }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sites = defaults.data(forKey: "sites").flatMap { try? JSONDecoder().decode([Site].self, from: $0) } ?? []
        preferences = defaults.data(forKey: "preferences").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        selected = defaults.string(forKey: "selected").flatMap(UUID.init(uuidString:))
        sites = sites.filter { websiteURL($0.url.absoluteString) != nil }
        if !sites.contains(where: { $0.id == selected }) { selected = sites.first?.id }
        if !preferences.width.isFinite { preferences.width = 480 }
        if !preferences.height.isFinite { preferences.height = 680 }
        preferences.width = max(360, preferences.width)
        preferences.height = max(300, preferences.height)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

func runChecks() throws {
    precondition(websiteURL(" chat.deepseek.com ")?.absoluteString == "https://chat.deepseek.com")
    precondition(websiteURL("https://chatgpt.com/c/example?q=a%20b")?.path == "/c/example")
    precondition(websiteURL("http://localhost:8080") != nil)
    precondition(websiteURL("https://intranet") != nil)
    for invalid in ["", "hello world", "hello", "javascript:alert(1)", "file:///tmp/a", "https://user:pass@example.com", "https://example.com:99999"] {
        precondition(websiteURL(invalid) == nil, "Accepted invalid URL: \(invalid)")
    }
    let now = ContinuousClock.now
    let first = UUID(), second = UUID()
    var retention = Retention()
    retention.suspend(first, at: now)
    retention.suspend(first, at: now.advanced(by: .seconds(20)))
    precondition(retention.expired(at: now.advanced(by: .seconds(29))).isEmpty)
    precondition(retention.expired(at: now.advanced(by: .seconds(30))) == [first])
    retention.activate(first)
    retention.suspend(second, at: now.advanced(by: .seconds(5)))
    precondition(retention.expired(at: now.advanced(by: .seconds(34))).isEmpty)
    precondition(retention.expired(at: now.advanced(by: .seconds(100))) == [second])
    retention.activate(second)
    precondition(retention.next == nil)
    retention.delay = nil
    retention.suspend(first, at: now)
    precondition(retention.next == nil)
    retention.delay = 75
    retention.suspend(first, at: now)
    precondition(retention.expired(at: now.advanced(by: .seconds(74))).isEmpty)
    precondition(retention.expired(at: now.advanced(by: .seconds(75))) == [first])
    let site = Site(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com/")!)
    let decoded = try JSONDecoder().decode([Site].self, from: JSONEncoder().encode([site]))
    precondition(decoded == [site])
    let secondSite = Site(name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!)
    let thirdSite = Site(name: "Example", url: URL(string: "https://example.com/")!)
    let ordered = [site, secondSite, thirdSite]
    precondition(reorderedSites(ordered, source: site.id, target: thirdSite.id) == [secondSite, thirdSite, site])
    precondition(reorderedSites(ordered, source: thirdSite.id, target: site.id) == [thirdSite, site, secondSite])
    precondition(reorderedSites(ordered, source: UUID(), target: site.id) == ordered)
    let oldPreferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"width":520,"pinned":true}"#.utf8))
    precondition(oldPreferences.width == 520 && oldPreferences.height == 680 && oldPreferences.pinned)
    precondition(oldPreferences.sleepEnabled && oldPreferences.sleepSeconds == 30)
    var resized = Preferences()
    resized.width = 620; resized.height = 450
    resized.sleepEnabled = false; resized.sleepSeconds = 75
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(resized))
    precondition(restored.width == 620 && restored.height == 450)
    precondition(!restored.sleepEnabled && restored.sleepSeconds == 75)
    print("PASS: URL validation, configurable deadlines, disabled sleep, cancellation, sleep recovery, persistence encoding")
}
