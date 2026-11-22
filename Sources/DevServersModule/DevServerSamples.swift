import Foundation
import Synchronization

/// Invented servers for `--fixtures`, the playground and screenshots. No real path, user or project.
enum DevServerSamples {
    static let home = "/Users/sample"

    static let servers: [DevServer] = [
        DevServer(
            pid: 41_207, port: 3000, command: "node", executablePath: "/usr/local/bin/node",
            workingDirectory: "\(home)/Projects/docs", startTime: ProcessStartTime(seconds: 1_700_000_300), hosts: ["*"]
        ),
        DevServer(
            pid: 41_388, port: 5173, command: "node", executablePath: "/usr/local/bin/node",
            workingDirectory: "\(home)/Projects/storefront", startTime: ProcessStartTime(seconds: 1_700_000_600),
            hosts: ["127.0.0.1", "[::1]"]
        ),
        DevServer(
            pid: 41_502, port: 8000, command: "python3", executablePath: "/usr/local/bin/python3",
            workingDirectory: "\(home)/Projects/api", startTime: ProcessStartTime(seconds: 1_700_000_900), hosts: ["127.0.0.1"]
        ),
        DevServer(
            pid: 41_633, port: 8080, command: "ruby", executablePath: "/usr/local/bin/ruby",
            workingDirectory: "\(home)/Projects/blog", startTime: ProcessStartTime(seconds: 1_700_001_200), hosts: ["[::1]"]
        ),
    ]
}

/// The fixture's scanner: answers from the sample list, from which the fixture's Stop removes a server.
final class SampleScanner: DevServerScanning {
    private let state: Mutex<[DevServer]>

    init(_ servers: [DevServer] = DevServerSamples.servers) { state = Mutex(servers) }

    func scan() async throws(ScanError) -> [DevServer] { state.withLock { $0 } }

    func remove(pid: Int32) { state.withLock { $0.removeAll { $0.pid == pid } } }
}
