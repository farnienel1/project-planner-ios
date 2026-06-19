//
//  SimpleZipWriter.swift
//  Project Planner
//
//  Minimal ZIP writer (store-only) for generating .xlsx files without third-party dependencies.
//

import Foundation

enum SimpleZipWriter {
    static func writeArchive(entries: [String: Data], to url: URL) throws {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            let offset = UInt32(archive.count)
            let fileNameData = Data(path.utf8)
            let crc = crc32(data)

            var localHeader = Data()
            localHeader.appendUInt32(0x04034b50)
            localHeader.appendUInt16(20)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(0)
            localHeader.appendUInt16(0)
            localHeader.appendUInt32(crc)
            localHeader.appendUInt32(UInt32(data.count))
            localHeader.appendUInt32(UInt32(data.count))
            localHeader.appendUInt16(UInt16(fileNameData.count))
            localHeader.appendUInt16(0)
            localHeader.append(fileNameData)
            localHeader.append(data)

            archive.append(localHeader)

            var centralHeader = Data()
            centralHeader.appendUInt32(0x02014b50)
            centralHeader.appendUInt16(20)
            centralHeader.appendUInt16(20)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt32(crc)
            centralHeader.appendUInt32(UInt32(data.count))
            centralHeader.appendUInt32(UInt32(data.count))
            centralHeader.appendUInt16(UInt16(fileNameData.count))
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt16(0)
            centralHeader.appendUInt32(0)
            centralHeader.appendUInt32(offset)
            centralHeader.append(fileNameData)

            centralDirectory.append(centralHeader)
            entryCount += 1
        }

        let centralOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        var endRecord = Data()
        endRecord.appendUInt32(0x06054b50)
        endRecord.appendUInt16(0)
        endRecord.appendUInt16(0)
        endRecord.appendUInt16(entryCount)
        endRecord.appendUInt16(entryCount)
        endRecord.appendUInt32(UInt32(centralDirectory.count))
        endRecord.appendUInt32(centralOffset)
        endRecord.appendUInt16(0)
        archive.append(endRecord)

        try archive.write(to: url, options: .atomic)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}
