import Darwin
import Foundation
import RouteBarCore

final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire() throws -> SingleInstanceLock? {
        let directory = AppSettings.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

        while flock(descriptor, LOCK_EX | LOCK_NB) == -1 {
            let code = errno
            if code == EINTR { continue }
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Keep the file in place so every launch locks the same inode.
        return SingleInstanceLock(descriptor: descriptor)
    }
}
