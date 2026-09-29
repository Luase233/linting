import Foundation

enum LegacyHealthCleanup {
    static func run() {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let cache = files.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let archive = support.appendingPathComponent("HealthArchive", isDirectory: true)
        let compatibility = cache.appendingPathComponent("BGMHealthCompatibility.json")
        if files.fileExists(atPath: archive.path) { try? files.removeItem(at: archive) }
        if files.fileExists(atPath: compatibility.path) { try? files.removeItem(at: compatibility) }
        // Retry the directory deletion on every launch if file protection prevents it.
        guard !files.fileExists(atPath: archive.path) else { return }
        for key in ["healthArchiveEnabled", "healthArchiveLastSync",
                    "healthArchiveUnavailableTypes", "healthArchivePaused"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
