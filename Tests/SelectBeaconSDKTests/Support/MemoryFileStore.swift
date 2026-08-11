import Foundation
@testable import SelectBeaconSDK

final class MemoryFileStore: FileStoring, @unchecked Sendable {
    private(set) var files: [URL: Data] = [:]
    private(set) var createdDirectories: [URL] = []
    /// Tracks Data Protection applied by create/write/migrate. Absent until protected.
    private(set) var protectionByURL: [URL: FileProtectionType] = [:]

    func data(at url: URL) throws -> Data? {
        files[url]
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url)
        protectionByURL[url] = DefaultFileStore.durableFileProtection
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        files[url] = data
        protectionByURL[url] = DefaultFileStore.durableFileProtection
    }

    func applyDataProtection(at url: URL) throws {
        if files[url] != nil || createdDirectories.contains(url) {
            protectionByURL[url] = DefaultFileStore.durableFileProtection
        }
    }

    /// Seeds an on-disk payload **without** protection (simulates a pre-migration file).
    func seed(_ data: Data, at url: URL) {
        files[url] = data
        protectionByURL.removeValue(forKey: url)
    }
}
