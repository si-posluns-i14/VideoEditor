import Foundation

enum RecentWorkspaces {
    private static let key = "recentWorkspaces"
    private static let limit = 10

    static func load() -> [URL] {
        migrateFromStreamCutterIfNeeded()
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    /// Changing the app's bundle id moved UserDefaults to a new domain, so pull the old
    /// recents across once rather than showing an empty list.
    private static func migrateFromStreamCutterIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.stringArray(forKey: key) == nil,
              !defaults.bool(forKey: "migratedFromStreamCutter"),
              let legacy = UserDefaults(suiteName: "local.streamcutter.app"),
              let paths = legacy.stringArray(forKey: key), !paths.isEmpty else {
            defaults.set(true, forKey: "migratedFromStreamCutter")
            return
        }
        defaults.set(paths, forKey: key)
        defaults.set(true, forKey: "migratedFromStreamCutter")
    }

    static func remember(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
        UserDefaults.standard.set(paths, forKey: key)
    }

    static func forget(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        UserDefaults.standard.set(paths, forKey: key)
    }

    /// Recents that still exist on disk.
    static func valid() -> [URL] {
        load().filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
