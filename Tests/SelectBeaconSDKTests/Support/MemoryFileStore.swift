import Foundation
@testable import SelectBeaconSDK

final class MemoryFileStore: FileStoring, @unchecked Sendable {
    private(set) var files: [URL: Data] = [:]
    private(set) var createdDirectories: [URL] = []

    func data(at url: URL) throws -> Data? {
        files[url]
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url)
    }

    func writeAtomically(_ data: Data, to url: URL) throws {
        files[url] = data
    }

    func seed(_ data: Data, at url: URL) {
        files[url] = data
    }
}
