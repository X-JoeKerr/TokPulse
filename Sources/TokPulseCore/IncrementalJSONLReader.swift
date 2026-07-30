import Darwin
import Foundation

struct SessionFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

struct SessionFileMetadata: Equatable {
    let identity: SessionFileIdentity
    let modifiedAt: Date
    let size: Int64
}

func sessionFileMetadata(_ file: URL) -> SessionFileMetadata? {
    var information = stat()
    guard lstat(file.path, &information) == 0 else {
        return nil
    }
    let seconds = TimeInterval(information.st_mtimespec.tv_sec)
    let nanoseconds = TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
    return SessionFileMetadata(
        identity: SessionFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        ),
        modifiedAt: Date(timeIntervalSince1970: seconds + nanoseconds),
        size: Int64(information.st_size)
    )
}

final class IncrementalJSONLReader {
    private let file: URL
    private var offset: UInt64 = 0
    private var lineNumber = 0

    init(file: URL) {
        self.file = file
    }

    func readAppended(_ body: (Data, Int) throws -> Void) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        var bytesRead: Int64 = 0
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            bytesRead += Int64(chunk.count)
            buffer.append(chunk)

            var consumed = buffer.startIndex
            while let newline = buffer[consumed...].firstIndex(of: 0x0A) {
                var end = newline
                if end > consumed, buffer[buffer.index(before: end)] == 0x0D {
                    end = buffer.index(before: end)
                }
                lineNumber += 1
                if end > consumed {
                    try body(Data(buffer[consumed..<end]), lineNumber)
                }
                consumed = buffer.index(after: newline)
                if consumed == buffer.endIndex {
                    break
                }
            }
            if consumed > buffer.startIndex {
                let consumedByteCount = buffer.distance(
                    from: buffer.startIndex,
                    to: consumed
                )
                offset += UInt64(consumedByteCount)
                buffer.removeSubrange(buffer.startIndex..<consumed)
            }
        }
        // Do not retain an unterminated JSON object because it can contain prompt
        // or tool payload text. The next append rereads only this short tail.
        return bytesRead
    }
}
