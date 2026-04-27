import Foundation

struct SymbolicationOutcome {
    let frames: [SymbolicatedFrame]
    let matchedImages: [BinaryImage]
    let primaryImage: BinaryImage
    let primaryMatchKind: SymbolicationMatchKind
}

final class SymbolicationService {
    private let executor = CommandExecutor()

    func symbolicate(report: CrashReport, dsym: DSYMInspectionResult) throws -> SymbolicationOutcome {
        guard let crashThread = report.crashedThread else {
            throw CrashAnalyzerError.missingCrashThread
        }

        let dsymMap = Dictionary(uniqueKeysWithValues: dsym.binaries.map { ($0.normalizedUUID, $0) })
        let dsymNameMap = Dictionary(grouping: dsym.binaries, by: { $0.imageName.lowercased() })
        let matchedImages = report.binaryImages.filter {
            resolveMatch(for: $0, uuidMap: dsymMap, nameMap: dsymNameMap) != nil
        }

        guard !matchedImages.isEmpty else {
            if report.binaryImages.contains(where: { $0.hasUUID }) {
                throw CrashAnalyzerError.uuidMismatch(
                    crashUUIDs: report.binaryImages.filter { $0.hasUUID }.map(\.uuid),
                    dsymUUIDs: dsym.uuids
                )
            }

            throw CrashAnalyzerError.imageNameMismatch(
                crashImages: report.binaryImages.map(\.name),
                dsymImages: dsym.binaries.map(\.imageName)
            )
        }

        let primaryImage = crashThread.frames
            .compactMap { frame in
                report.binaryImages.first(where: {
                    $0.name == frame.imageName && resolveMatch(for: $0, uuidMap: dsymMap, nameMap: dsymNameMap) != nil
                })
            }
            .first ?? matchedImages[0]
        let primaryMatchKind = resolveMatch(for: primaryImage, uuidMap: dsymMap, nameMap: dsymNameMap)?.kind ?? .none

        let primaryIndex = crashThread.frames.firstIndex(where: { frame in
            guard let image = report.binaryImages.first(where: { $0.name == frame.imageName }) else {
                return false
            }
            return resolveMatch(for: image, uuidMap: dsymMap, nameMap: dsymNameMap) != nil
        }) ?? 0

        let frames = crashThread.frames.enumerated().map { position, frame in
            let image = report.binaryImages.first(where: { $0.name == frame.imageName })
            let resolution = image.flatMap { resolveMatch(for: $0, uuidMap: dsymMap, nameMap: dsymNameMap) }
            let matchedBinaries = resolution?.binaries ?? []

            let parsedSymbol: ParsedSymbolInfo
            let note: String?
            let matchKind = resolution?.kind ?? .none

            if let image, !matchedBinaries.isEmpty {
                if let symbolicated = symbolicate(frame: frame, image: image, dsymBinaries: matchedBinaries) {
                    parsedSymbol = symbolicated
                    note = matchKind == .imageName ? "日志未提供该镜像 UUID，已按镜像名匹配 dSYM。" : nil
                } else if let parsedRawSymbol = frame.parsedRawSymbol {
                    parsedSymbol = parsedRawSymbol
                    note = matchKind == .imageName ? "日志未提供该镜像 UUID，atos 解析失败后已回退到原始符号。" : "atos 解析失败，已回退到日志中的原始符号。"
                } else {
                    parsedSymbol = ParsedSymbolInfo.from(rawText: frame.rawSymbol ?? "未解析到符号")
                    note = matchKind == .imageName ? "日志未提供该镜像 UUID，atos 未返回可用结果。" : "atos 未返回可用结果。"
                }
            } else if let parsedRawSymbol = frame.parsedRawSymbol {
                parsedSymbol = parsedRawSymbol
                note = "当前帧未命中所选 dSYM UUID，保留原始符号。"
            } else {
                parsedSymbol = ParsedSymbolInfo.from(rawText: frame.rawSymbol ?? "未解析到符号")
                note = "当前帧未命中所选 dSYM UUID。"
            }

            return SymbolicatedFrame(
                id: "\(frame.index)-\(frame.instructionAddress.hexAddress)-\(frame.imageName)",
                index: frame.index,
                imageName: frame.imageName,
                address: frame.instructionAddress.hexAddress,
                moduleOrClassName: parsedSymbol.moduleOrClassName,
                functionName: parsedSymbol.functionName,
                filePath: parsedSymbol.filePath,
                fileName: parsedSymbol.fileName,
                lineNumber: parsedSymbol.lineNumber,
                rawText: parsedSymbol.rawText,
                note: note,
                matchKind: matchKind,
                isLikelyRootCause: position == primaryIndex
            )
        }

        return SymbolicationOutcome(
            frames: frames,
            matchedImages: matchedImages,
            primaryImage: primaryImage,
            primaryMatchKind: primaryMatchKind
        )
    }

    private func symbolicate(frame: CrashFrame, image: BinaryImage, dsymBinaries: [DSYMBinary]) -> ParsedSymbolInfo? {
        for candidate in prioritizeCandidates(dsymBinaries, for: image) {
            var candidateArchitectures = [normalizedArchitecture(candidate.arch)]
            if candidateArchitectures.first == "arm64e" {
                candidateArchitectures.append("arm64")
            }

            for arch in candidateArchitectures where !arch.isEmpty {
                if let result = runAtos(frame: frame, image: image, dsymBinary: candidate, arch: arch) {
                    return result
                }
            }
        }

        return nil
    }

    private func runAtos(frame: CrashFrame, image: BinaryImage, dsymBinary: DSYMBinary, arch: String) -> ParsedSymbolInfo? {
        let arguments = [
            "atos",
            "-arch", arch,
            "-fullPath",
            "-o", dsymBinary.executableURL.path,
            "-l", image.baseAddress.hexAddress,
            frame.instructionAddress.hexAddress,
        ]

        guard let output = try? executor.run(arguments: arguments), !output.isEmpty else {
            return nil
        }

        let parsed = ParsedSymbolInfo.from(rawText: output)
        if parsed.functionName.hasPrefix("0x") && parsed.fileName == nil {
            return nil
        }
        return parsed
    }

    private func prioritizeCandidates(_ dsymBinaries: [DSYMBinary], for image: BinaryImage) -> [DSYMBinary] {
        let preferredArch = normalizedArchitecture(image.arch ?? "")
        guard !preferredArch.isEmpty else {
            return dsymBinaries
        }

        let preferred = dsymBinaries.filter { normalizedArchitecture($0.arch) == preferredArch }
        let fallback = dsymBinaries.filter { normalizedArchitecture($0.arch) != preferredArch }
        return preferred + fallback
    }

    private func normalizedArchitecture(_ arch: String) -> String {
        arch.replacingOccurrences(of: "arm64e", with: "arm64e")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }

    private func resolveMatch(
        for image: BinaryImage,
        uuidMap: [String: DSYMBinary],
        nameMap: [String: [DSYMBinary]]
    ) -> (binaries: [DSYMBinary], kind: SymbolicationMatchKind)? {
        if image.hasUUID, let binary = uuidMap[image.normalizedUUID] {
            return ([binary], .uuid)
        }

        guard !image.hasUUID, let binaries = nameMap[image.name.lowercased()], !binaries.isEmpty else {
            return nil
        }

        return (binaries, .imageName)
    }
}
