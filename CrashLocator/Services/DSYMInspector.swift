import Foundation

final class DSYMInspector {
    private let executor = CommandExecutor()

    func inspect(at dsymURL: URL) throws -> DSYMInspectionResult {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: dsymURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            dsymURL.pathExtension.lowercased() == "dsym"
        else {
            throw CrashAnalyzerError.invalidDSYM
        }

        let dwarfDirectory = dsymURL.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: dwarfDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }

        guard !files.isEmpty else {
            throw CrashAnalyzerError.invalidDSYM
        }

        let binaries = try files.flatMap { fileURL in
            let output = try executor.run(arguments: ["dwarfdump", "--uuid", fileURL.path])
            return parseDwarfdump(output: output, executableURL: fileURL)
        }

        guard !binaries.isEmpty else {
            throw CrashAnalyzerError.invalidDSYM
        }

        return DSYMInspectionResult(bundleURL: dsymURL, binaries: binaries)
    }

    private func parseDwarfdump(output: String, executableURL: URL) -> [DSYMBinary] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line in
                let pattern = #"^UUID:\s+([0-9A-Fa-f\-]+)\s+\(([^)]+)\)\s+(.+)$"#
                guard let match = line.firstMatch(pattern: pattern) else {
                    return nil
                }
                return DSYMBinary(uuid: match[1], arch: match[2], executableURL: executableURL)
            }
    }
}
