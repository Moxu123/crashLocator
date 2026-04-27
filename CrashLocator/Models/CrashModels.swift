import Foundation

enum InputTarget {
    case crashLog
    case dsym

    var title: String {
        switch self {
        case .crashLog:
            return "崩溃日志"
        case .dsym:
            return "dSYM"
        }
    }
}

enum AnalysisStatus: Equatable {
    case idle(String)
    case running(String)
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case let .idle(message), let .running(message), let .success(message), let .failure(message):
            return message
        }
    }
}

enum CrashAnalyzerError: LocalizedError {
    case invalidCrashLog
    case invalidDSYM
    case missingCrashThread
    case uuidMismatch(crashUUIDs: [String], dsymUUIDs: [String])
    case imageNameMismatch(crashImages: [String], dsymImages: [String])
    case commandFailed(command: String, output: String)
    case symbolicationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCrashLog:
            return "崩溃日志格式无法识别，支持 .crash / .txt / .ips 文本日志。"
        case .invalidDSYM:
            return "所选路径不是有效的 .dSYM 目录，或目录下缺少 DWARF 符号文件。"
        case .missingCrashThread:
            return "崩溃日志中未找到有效的崩溃线程。"
        case let .uuidMismatch(crashUUIDs, dsymUUIDs):
            return """
            UUID 不匹配，已阻止符号化。
            崩溃日志 UUID: \(crashUUIDs.joined(separator: ", "))
            dSYM UUID: \(dsymUUIDs.joined(separator: ", "))
            """
        case let .imageNameMismatch(crashImages, dsymImages):
            return """
            崩溃日志未提供可用 UUID，且无法根据镜像名匹配到所选 dSYM。
            崩溃日志镜像: \(crashImages.joined(separator: ", "))
            dSYM 镜像: \(dsymImages.joined(separator: ", "))
            """
        case let .commandFailed(command, output):
            return "系统命令执行失败：\(command)\n\(output)"
        case let .symbolicationFailed(reason):
            return "符号化失败：\(reason)"
        }
    }
}

enum CrashReportFormat {
    case text
    case ips
    case customJSON
}

struct CrashReport {
    let format: CrashReportFormat
    let exceptionType: String
    let exceptionReason: String?
    let terminationReason: String?
    let applicationSpecificInformation: String?
    let crashedThreadNumber: Int?
    let threads: [CrashThread]
    let binaryImages: [BinaryImage]

    var crashedThread: CrashThread? {
        if let crashedThreadNumber {
            return threads.first(where: { $0.number == crashedThreadNumber })
        }
        return threads.first(where: \.crashed)
    }
}

struct CrashThread {
    let number: Int
    let crashed: Bool
    let name: String?
    let frames: [CrashFrame]
}

struct CrashFrame {
    let index: Int
    let imageName: String
    let instructionAddress: UInt64
    let rawSymbol: String?
    let parsedRawSymbol: ParsedSymbolInfo?
}

struct BinaryImage {
    let name: String
    let arch: String?
    let uuid: String
    let path: String?
    let baseAddress: UInt64
    let endAddress: UInt64?

    var normalizedUUID: String {
        uuid.normalizedUUID
    }

    var hasUUID: Bool {
        !normalizedUUID.isEmpty
    }
}

struct DSYMBinary {
    let uuid: String
    let arch: String
    let executableURL: URL

    var normalizedUUID: String {
        uuid.normalizedUUID
    }

    var imageName: String {
        executableURL.lastPathComponent
    }
}

struct DSYMInspectionResult {
    let bundleURL: URL
    let binaries: [DSYMBinary]

    var uuids: [String] {
        binaries.map(\.uuid)
    }
}

enum SymbolicationMatchKind {
    case uuid
    case imageName
    case none

    var tagText: String {
        switch self {
        case .uuid:
            return "[UUID已匹配]"
        case .imageName:
            return "[按镜像名匹配]"
        case .none:
            return "[未命中dSYM]"
        }
    }
}

struct ParsedSymbolInfo {
    let rawText: String
    let functionName: String
    let moduleOrClassName: String?
    let filePath: String?
    let fileName: String?
    let lineNumber: Int?

    static func from(rawText: String) -> ParsedSymbolInfo {
        let collapsed = rawText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let filePattern = #"^(.*?)\s+\(in\s+([^)]+)\)\s+\((.*?):(\d+)\)$"#
        if let match = collapsed.firstMatch(pattern: filePattern) {
            let functionName = match[1].strippingOffsetSuffix()
            let module = match[2].trimmingCharacters(in: .whitespaces)
            let filePath = match[3].trimmingCharacters(in: .whitespaces)
            let lineNumber = Int(match[4])
            return ParsedSymbolInfo(
                rawText: collapsed,
                functionName: functionName,
                moduleOrClassName: deriveModuleOrClass(from: functionName, preferredModule: module),
                filePath: filePath,
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                lineNumber: lineNumber
            )
        }

        let shortFilePattern = #"^(.*?)\s+\((.*?):(\d+)\)$"#
        if let match = collapsed.firstMatch(pattern: shortFilePattern) {
            let functionName = match[1].strippingOffsetSuffix()
            let filePath = match[2].trimmingCharacters(in: .whitespaces)
            let lineNumber = Int(match[3])
            return ParsedSymbolInfo(
                rawText: collapsed,
                functionName: functionName,
                moduleOrClassName: deriveModuleOrClass(from: functionName, preferredModule: nil),
                filePath: filePath,
                fileName: URL(fileURLWithPath: filePath).lastPathComponent,
                lineNumber: lineNumber
            )
        }

        let functionName = collapsed.strippingOffsetSuffix()
        return ParsedSymbolInfo(
            rawText: collapsed,
            functionName: functionName.isEmpty ? "未解析到符号" : functionName,
            moduleOrClassName: deriveModuleOrClass(from: functionName, preferredModule: nil),
            filePath: nil,
            fileName: nil,
            lineNumber: nil
        )
    }

    private static func deriveModuleOrClass(from functionName: String, preferredModule: String?) -> String? {
        let objcPattern = #"^[+-]\[([^\s]+)\s+.*\]$"#
        if let match = functionName.firstMatch(pattern: objcPattern) {
            return match[1]
        }

        let scopeSource = functionName.components(separatedBy: " in ").last?.trimmingCharacters(in: .whitespaces) ?? functionName
        let signature = scopeSource.components(separatedBy: "(").first ?? scopeSource
        let pieces = signature.split(separator: ".").map(String.init)
        guard pieces.count > 1 else {
            if let preferredModule, !preferredModule.isEmpty {
                return preferredModule
            }
            return nil
        }
        return pieces.dropLast().joined(separator: ".")
    }
}

struct SymbolicatedFrame: Identifiable {
    let id: String
    let index: Int
    let imageName: String
    let address: String
    let moduleOrClassName: String?
    let functionName: String
    let filePath: String?
    let fileName: String?
    let lineNumber: Int?
    let rawText: String
    let note: String?
    let matchKind: SymbolicationMatchKind
    let isLikelyRootCause: Bool
}

struct CrashSummary {
    let exceptionType: String
    let reason: String?
    let crashedThread: String
    let binaryImageName: String
    let binaryImageUUID: String
    let binaryImageMatchMethod: String
    let dsymUUIDs: [String]
    let fileName: String?
    let classOrModuleName: String?
    let functionName: String
    let lineNumber: Int?
    let diagnosis: String
}

struct CrashAnalysisResult {
    let summary: CrashSummary
    let frames: [SymbolicatedFrame]
    let fullTextReport: String
}

extension String {
    var normalizedUUID: String {
        uppercased().replacingOccurrences(of: "-", with: "")
    }

    func firstMatch(pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let match = regex.firstMatch(in: self, options: [], range: range) else {
            return nil
        }
        return (0..<match.numberOfRanges).map { index in
            let matchRange = match.range(at: index)
            guard matchRange.location != NSNotFound else {
                return ""
            }
            guard let range = Range(matchRange, in: self) else {
                return ""
            }
            return String(self[range])
        }
    }

    func strippingOffsetSuffix() -> String {
        replacingOccurrences(of: #"\s+\+\s+\d+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension UInt64 {
    var hexAddress: String {
        String(format: "0x%016llx", self)
    }
}
