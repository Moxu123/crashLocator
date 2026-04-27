import Foundation

final class CrashLogParser {
    func parse(url: URL) throws -> CrashReport {
        let data = try Data(contentsOf: url)
        let candidates: [String.Encoding] = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .ascii]
        for encoding in candidates {
            if let text = String(data: data, encoding: encoding) {
                return try parse(text: text)
            }
        }
        throw CrashAnalyzerError.invalidCrashLog
    }

    func parse(text: String) throws -> CrashReport {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CrashAnalyzerError.invalidCrashLog
        }
        if trimmed.first == "{" {
            return try parseStructuredJSON(text: trimmed)
        }
        return try parseTextCrash(text: text)
    }

    private func parseStructuredJSON(text: String) throws -> CrashReport {
        guard
            let data = text.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CrashAnalyzerError.invalidCrashLog
        }

        if json["threads"] != nil || json["usedImages"] != nil || json["faultingThread"] != nil {
            return try parseIPS(json: json)
        }

        if json["callStackSymbols"] != nil {
            return try parseCustomJSON(json: json)
        }

        throw CrashAnalyzerError.invalidCrashLog
    }

    private func parseTextCrash(text: String) throws -> CrashReport {
        struct ThreadBuilder {
            var number: Int
            var crashed: Bool
            var name: String?
            var frames: [CrashFrame]
        }

        var exceptionType = "未识别异常"
        var exceptionReason: String?
        var terminationReason: String?
        var applicationSpecificLines: [String] = []
        var crashedThreadNumber: Int?
        var threads: [CrashThread] = []
        var binaryImages: [BinaryImage] = []
        var currentThread: ThreadBuilder?
        var inBinaryImages = false
        var collectingAppInfo = false
        var threadNames: [Int: String] = [:]

        func appendCurrentThread() {
            guard let currentThread else {
                return
            }
            threads.append(
                CrashThread(
                    number: currentThread.number,
                    crashed: currentThread.crashed,
                    name: currentThread.name ?? threadNames[currentThread.number],
                    frames: currentThread.frames
                )
            )
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if rawLine.hasPrefix("Binary Images:") {
                appendCurrentThread()
                currentThread = nil
                inBinaryImages = true
                collectingAppInfo = false
                continue
            }

            if inBinaryImages {
                if let image = parseBinaryImage(line: rawLine) {
                    binaryImages.append(image)
                }
                continue
            }

            if rawLine.hasPrefix("Application Specific Information:") {
                collectingAppInfo = true
                continue
            }

            if collectingAppInfo {
                if trimmed.isEmpty {
                    collectingAppInfo = false
                } else {
                    applicationSpecificLines.append(trimmed)
                }
                continue
            }

            if let value = rawLine.value(after: "Exception Type:") {
                exceptionType = value
                continue
            }

            if let value = rawLine.value(after: "Exception Reason:") {
                exceptionReason = value
                continue
            }

            if let value = rawLine.value(after: "Termination Reason:") {
                terminationReason = value
                continue
            }

            if let value = rawLine.value(after: "Crashed Thread:"), let number = Int(value.components(separatedBy: .whitespaces).first ?? "") {
                crashedThreadNumber = number
                continue
            }

            if let value = rawLine.value(after: "Triggered by Thread:"), let number = Int(value.components(separatedBy: .whitespaces).first ?? "") {
                crashedThreadNumber = number
                continue
            }

            if let threadName = parseThreadName(line: rawLine) {
                threadNames[threadName.number] = threadName.name
                if currentThread?.number == threadName.number {
                    currentThread?.name = threadName.name
                }
                continue
            }

            if let header = parseThreadHeader(line: rawLine) {
                appendCurrentThread()
                currentThread = ThreadBuilder(
                    number: header.number,
                    crashed: header.crashed,
                    name: threadNames[header.number],
                    frames: []
                )
                continue
            }

            if let frame = parseFrame(line: rawLine), currentThread != nil {
                currentThread?.frames.append(frame)
                continue
            }

            if trimmed.isEmpty, currentThread != nil {
                appendCurrentThread()
                currentThread = nil
            }
        }

        appendCurrentThread()

        if let crashedThreadNumber {
            threads = threads.map { thread in
                CrashThread(number: thread.number, crashed: thread.number == crashedThreadNumber, name: thread.name, frames: thread.frames)
            }
        }

        guard !threads.isEmpty, !binaryImages.isEmpty else {
            throw CrashAnalyzerError.invalidCrashLog
        }

        return CrashReport(
            format: .text,
            exceptionType: exceptionType,
            exceptionReason: exceptionReason,
            terminationReason: terminationReason,
            applicationSpecificInformation: applicationSpecificLines.isEmpty ? nil : applicationSpecificLines.joined(separator: "\n"),
            crashedThreadNumber: crashedThreadNumber,
            threads: threads,
            binaryImages: binaryImages
        )
    }

    private func parseIPS(json: [String: Any]) throws -> CrashReport {
        let exception = json["exception"] as? [String: Any]
        let exceptionType = (exception?["type"] as? String) ?? (json["exceptionType"] as? String) ?? "未识别异常"
        let exceptionReason = (exception?["reason"] as? String) ?? (json["reason"] as? String)
        let terminationReason = (json["termination"] as? [String: Any])?["details"] as? String
        let applicationSpecificInformation = json["applicationSpecificInformation"] as? String
        let crashedThreadNumber = Self.uint(from: json["faultingThread"]).map(Int.init)

        let usedImages = (json["usedImages"] as? [[String: Any]] ?? []).map { image -> BinaryImage in
            let name = (image["name"] as? String) ?? ((image["path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "Unknown"
            let arch = image["arch"] as? String
            let uuid = (image["uuid"] as? String) ?? ""
            let path = image["path"] as? String
            let baseAddress = Self.uint(from: image["base"]) ?? 0
            let size = Self.uint(from: image["size"])
            let endAddress = size.map { baseAddress + $0 }
            return BinaryImage(name: name, arch: arch, uuid: uuid, path: path, baseAddress: baseAddress, endAddress: endAddress)
        }

        let threads = (json["threads"] as? [[String: Any]] ?? []).enumerated().map { index, thread in
            let number = Int(Self.uint(from: thread["id"]) ?? UInt64(index))
            let crashed = (thread["triggered"] as? Bool ?? false) || (crashedThreadNumber == number)
            let name = thread["queue"] as? String ?? thread["name"] as? String
            let frames = (thread["frames"] as? [[String: Any]] ?? []).enumerated().map { frameIndex, frame -> CrashFrame in
                let imageIndex = Int(Self.uint(from: frame["imageIndex"]) ?? 0)
                let image = usedImages.indices.contains(imageIndex) ? usedImages[imageIndex] : nil
                let imageOffset = Self.uint(from: frame["imageOffset"]) ?? 0
                let instructionAddress = (image?.baseAddress ?? 0) + imageOffset
                let rawSymbol = frame["symbol"] as? String
                return CrashFrame(
                    index: frameIndex,
                    imageName: image?.name ?? (frame["imageName"] as? String ?? "Unknown"),
                    instructionAddress: instructionAddress,
                    rawSymbol: rawSymbol,
                    parsedRawSymbol: rawSymbol.map(ParsedSymbolInfo.from(rawText:))
                )
            }
            return CrashThread(number: number, crashed: crashed, name: name, frames: frames)
        }

        guard !threads.isEmpty, !usedImages.isEmpty else {
            throw CrashAnalyzerError.invalidCrashLog
        }

        return CrashReport(
            format: .ips,
            exceptionType: exceptionType,
            exceptionReason: exceptionReason,
            terminationReason: terminationReason,
            applicationSpecificInformation: applicationSpecificInformation,
            crashedThreadNumber: crashedThreadNumber,
            threads: threads,
            binaryImages: usedImages
        )
    }

    private func parseCustomJSON(json: [String: Any]) throws -> CrashReport {
        guard let callStackSymbols = json["callStackSymbols"] as? [String], !callStackSymbols.isEmpty else {
            throw CrashAnalyzerError.invalidCrashLog
        }

        let frames = callStackSymbols.compactMap(parseFrame(line:))
        guard !frames.isEmpty else {
            throw CrashAnalyzerError.invalidCrashLog
        }

        let exceptionType = (json["errorName"] as? String) ?? (json["exceptionName"] as? String) ?? "未识别异常"
        let exceptionReason = (json["errorReason"] as? String) ?? (json["reason"] as? String)
        let terminationReason = json["errorPlace"] as? String
        let applicationSpecificInformation = [
            json["defaultToDo"] as? String,
            json["exception"] as? String,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        return CrashReport(
            format: .customJSON,
            exceptionType: exceptionType,
            exceptionReason: exceptionReason,
            terminationReason: terminationReason,
            applicationSpecificInformation: applicationSpecificInformation.isEmpty ? nil : applicationSpecificInformation,
            crashedThreadNumber: 0,
            threads: [CrashThread(number: 0, crashed: true, name: "callStackSymbols", frames: frames)],
            binaryImages: buildBinaryImages(from: frames)
        )
    }

    private func parseThreadHeader(line: String) -> (number: Int, crashed: Bool)? {
        let pattern = #"^Thread\s+(\d+)(\s+Crashed)?\:$"#
        guard let match = line.trimmingCharacters(in: .whitespaces).firstMatch(pattern: pattern), let number = Int(match[1]) else {
            return nil
        }
        return (number, !match[2].isEmpty)
    }

    private func parseThreadName(line: String) -> (number: Int, name: String)? {
        let pattern = #"^Thread\s+(\d+)\s+name:\s+(.*)$"#
        guard let match = line.trimmingCharacters(in: .whitespaces).firstMatch(pattern: pattern), let number = Int(match[1]) else {
            return nil
        }
        return (number, match[2].trimmingCharacters(in: .whitespaces))
    }

    private func parseFrame(line: String) -> CrashFrame? {
        let pattern = #"^\s*(\d+)\s+(.+?)\s+0x([0-9A-Fa-f]+)\s+(.*)$"#
        guard let match = line.firstMatch(pattern: pattern) else {
            return nil
        }

        guard let index = Int(match[1]), let instructionAddress = UInt64(match[3], radix: 16) else {
            return nil
        }

        let rawSymbol = match[4].trimmingCharacters(in: .whitespaces)
        return CrashFrame(
            index: index,
            imageName: match[2].trimmingCharacters(in: .whitespaces),
            instructionAddress: instructionAddress,
            rawSymbol: rawSymbol,
            parsedRawSymbol: rawSymbol.isEmpty ? nil : ParsedSymbolInfo.from(rawText: rawSymbol)
        )
    }

    private func parseBinaryImage(line: String) -> BinaryImage? {
        let pattern = #"^\s*0x([0-9A-Fa-f]+)\s*-\s*0x([0-9A-Fa-f]+)\s+(.+?)\s+<([0-9A-Fa-f\-]+)>\s+(.*)$"#
        guard let match = line.firstMatch(pattern: pattern) else {
            return nil
        }

        guard let baseAddress = UInt64(match[1], radix: 16), let endAddress = UInt64(match[2], radix: 16) else {
            return nil
        }

        let imagePrefix = match[3].trimmingCharacters(in: .whitespaces)
        let pieces = imagePrefix.split(whereSeparator: \.isWhitespace).map(String.init)
        guard pieces.count >= 2 else {
            return nil
        }

        let arch = pieces.last
        let name = pieces.dropLast().joined(separator: " ")
        return BinaryImage(
            name: name,
            arch: arch,
            uuid: match[4],
            path: match[5].trimmingCharacters(in: .whitespaces),
            baseAddress: baseAddress,
            endAddress: endAddress
        )
    }

    private func buildBinaryImages(from frames: [CrashFrame]) -> [BinaryImage] {
        var imagesByKey: [String: BinaryImage] = [:]
        var orderedKeys: [String] = []

        for frame in frames {
            let key = frame.imageName.lowercased()
            let derivedBaseAddress = derivedBaseAddress(for: frame) ?? 0

            if let existing = imagesByKey[key] {
                if existing.baseAddress == 0, derivedBaseAddress != 0 {
                    imagesByKey[key] = BinaryImage(
                        name: existing.name,
                        arch: existing.arch,
                        uuid: existing.uuid,
                        path: existing.path,
                        baseAddress: derivedBaseAddress,
                        endAddress: existing.endAddress
                    )
                }
                continue
            }

            orderedKeys.append(key)
            imagesByKey[key] = BinaryImage(
                name: frame.imageName,
                arch: nil,
                uuid: "",
                path: nil,
                baseAddress: derivedBaseAddress,
                endAddress: nil
            )
        }

        return orderedKeys.compactMap { imagesByKey[$0] }
    }

    private func derivedBaseAddress(for frame: CrashFrame) -> UInt64? {
        guard let rawSymbol = frame.rawSymbol?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSymbol.isEmpty else {
            return nil
        }

        let pattern = "^" + NSRegularExpression.escapedPattern(for: frame.imageName) + #"\\s+\\+\\s+(\\d+)$"#
        guard let match = rawSymbol.firstMatch(pattern: pattern), let offset = UInt64(match[1]) else {
            return nil
        }

        guard frame.instructionAddress >= offset else {
            return nil
        }
        return frame.instructionAddress - offset
    }

    private static func uint(from value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber:
            return number.uint64Value
        case let string as String:
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasPrefix("0x") {
                return UInt64(cleaned.dropFirst(2), radix: 16)
            }
            return UInt64(cleaned)
        default:
            return nil
        }
    }
}

private extension String {
    func value(after prefix: String) -> String? {
        guard hasPrefix(prefix) else {
            return nil
        }
        return replacingOccurrences(of: prefix, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
