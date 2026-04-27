import Foundation

final class CrashAnalysisService {
    private let parser = CrashLogParser()
    private let dsymInspector = DSYMInspector()
    private let symbolicator = SymbolicationService()

    func analyze(crashLogURL: URL, dsymURL: URL) throws -> CrashAnalysisResult {
        let report = try parser.parse(url: crashLogURL)
        let dsym = try dsymInspector.inspect(at: dsymURL)
        let outcome = try symbolicator.symbolicate(report: report, dsym: dsym)

        guard let rootFrame = outcome.frames.first(where: \.isLikelyRootCause) ?? outcome.frames.first else {
            throw CrashAnalyzerError.symbolicationFailed("崩溃线程为空。")
        }

        let reason = report.exceptionReason ?? report.applicationSpecificInformation ?? report.terminationReason
        let diagnosis = inferDiagnosis(report: report, rootFrame: rootFrame)
        let crashedThreadLabel = report.crashedThread.map { "Thread \($0.number)" } ?? "未知线程"

        let summary = CrashSummary(
            exceptionType: report.exceptionType,
            reason: reason,
            crashedThread: crashedThreadLabel,
            binaryImageName: outcome.primaryImage.name,
            binaryImageUUID: displayUUID(for: outcome),
            binaryImageMatchMethod: matchMethodDescription(for: outcome.primaryMatchKind),
            dsymUUIDs: dsym.uuids,
            fileName: rootFrame.fileName,
            classOrModuleName: rootFrame.moduleOrClassName,
            functionName: rootFrame.functionName,
            lineNumber: rootFrame.lineNumber,
            diagnosis: diagnosis
        )

        let fullText = renderReport(
            summary: summary,
            report: report,
            frames: outcome.frames
        )

        return CrashAnalysisResult(summary: summary, frames: outcome.frames, fullTextReport: fullText)
    }

    private func inferDiagnosis(report: CrashReport, rootFrame: SymbolicatedFrame) -> String {
        let corpus = [
            report.exceptionType,
            report.exceptionReason,
            report.terminationReason,
            report.applicationSpecificInformation,
            rootFrame.functionName,
            rootFrame.rawText,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()

        if corpus.contains("exc_bad_access") || corpus.contains("sigsegv") || corpus.contains("kerns_invalid_address") {
            return "疑似非法内存访问或野指针问题，优先检查对象生命周期、越界读写与线程并发访问。"
        }

        if corpus.contains("unrecognized selector") {
            return "疑似向错误对象发送了 Objective-C selector，优先检查实例类型、方法签名与 category 是否正确加载。"
        }

        if corpus.contains("index out of range") || corpus.contains("array index") || corpus.contains("out of bounds") {
            return "疑似数组越界，优先检查集合访问前的边界判断。"
        }

        if corpus.contains("unexpectedly found nil") || corpus.contains("nil while implicitly unwrapping") {
            return "疑似 Swift 强制解包 nil，优先检查可选值链路与界面/数据初始化时序。"
        }

        if corpus.contains("watchdog") || corpus.contains("8badf00d") || corpus.contains("main thread") {
            return "疑似主线程长时间阻塞或卡顿，建议检查同步 I/O、锁等待、主线程耗时计算与死循环。"
        }

        if corpus.contains("fatal error") || corpus.contains("precondition") || corpus.contains("assertion failure") {
            return "疑似主动触发了 fatalError / assert / precondition，优先检查业务保护条件和不变量。"
        }

        return "优先检查崩溃线程首个命中的业务帧及其上下文参数，当前定位结果已经给出最可能的问题入口。"
    }

    private func renderReport(summary: CrashSummary, report: CrashReport, frames: [SymbolicatedFrame]) -> String {
        let stackLines = frames.map { frame -> String in
            let location = if let fileName = frame.fileName {
                "\(fileName):\(frame.lineNumber.map(String.init) ?? "?")"
            } else {
                "未定位到源码行"
            }

            let tags = [
                frame.isLikelyRootCause ? "[疑似问题帧]" : nil,
                frame.matchKind.tagText,
            ]
            .compactMap { $0 }
            .joined(separator: "")

            let noteSuffix = frame.note.map { " | \($0)" } ?? ""
            return "\(tags) #\(frame.index) \(frame.imageName) \(frame.address) \(frame.functionName) | \(location)\(noteSuffix)"
        }
        .joined(separator: "\n")

        return """
        【镜像匹配】
        崩溃日志命中镜像 UUID: \(summary.binaryImageUUID)
        dSYM UUID: \(summary.dsymUUIDs.joined(separator: ", "))
        匹配方式: \(summary.binaryImageMatchMethod)

        【崩溃摘要】
        异常类型: \(summary.exceptionType)
        异常原因: \(summary.reason ?? "未提供")
        崩溃线程: \(summary.crashedThread)
        命中镜像: \(summary.binaryImageName)

        【精准定位】
        文件名: \(summary.fileName ?? "未定位")
        类名/模块名: \(summary.classOrModuleName ?? "未定位")
        方法/函数名: \(summary.functionName)
        代码行号: \(summary.lineNumber.map(String.init) ?? "未定位")

        【原因推断】
        \(summary.diagnosis)

        【完整符号化调用栈】
        \(stackLines)

        【补充信息】
        Termination Reason: \(report.terminationReason ?? "未提供")
        App Specific Information:
        \(report.applicationSpecificInformation ?? "未提供")
        """
    }

    private func displayUUID(for outcome: SymbolicationOutcome) -> String {
        if outcome.primaryMatchKind == .uuid, !outcome.primaryImage.uuid.isEmpty {
            return outcome.primaryImage.uuid
        }
        return "未提供"
    }

    private func matchMethodDescription(for kind: SymbolicationMatchKind) -> String {
        switch kind {
        case .uuid:
            return "UUID 匹配"
        case .imageName:
            return "日志未提供 UUID，已按镜像名匹配"
        case .none:
            return "未匹配"
        }
    }
}
