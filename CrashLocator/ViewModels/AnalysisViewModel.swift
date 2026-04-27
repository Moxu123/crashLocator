import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published var crashLogURL: URL?
    @Published var dsymURL: URL?
    @Published var status: AnalysisStatus = .idle("请选择崩溃日志与 dSYM，然后开始分析。")
    @Published var result: CrashAnalysisResult?

    var canAnalyze: Bool {
        crashLogURL != nil && dsymURL != nil && !isRunning
    }

    var isRunning: Bool {
        if case .running = status {
            return true
        }
        return false
    }

    var outputText: String {
        result?.fullTextReport ?? """
        结果区支持滚动、复制、全选。

        使用步骤：
        1. 选择或拖拽崩溃日志
        2. 选择或拖拽对应 dSYM
        3. 点击“开始分析”
        """
    }

    func selectCrashLog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择崩溃日志"
        panel.message = "支持 .crash / .txt / .ips / .json"
        panel.allowedContentTypes = [.plainText, .json, UTType(filenameExtension: "crash"), UTType(filenameExtension: "ips"), UTType(filenameExtension: "txt")].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        apply(url: url, for: .crashLog)
    }

    func selectDSYM() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "选择 dSYM 目录"
        panel.message = "请选择 .dSYM 文件夹"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        apply(url: url, for: .dsym)
    }

    func clear(_ target: InputTarget) {
        switch target {
        case .crashLog:
            crashLogURL = nil
        case .dsym:
            dsymURL = nil
        }
        result = nil
        status = .idle("已清空 \(target.title)，请重新选择。")
    }

    func handleDrop(urls: [URL], for target: InputTarget) {
        guard let url = urls.first else {
            return
        }
        apply(url: url, for: target)
    }

    func analyze() {
        guard let crashLogURL, let dsymURL else {
            status = .failure("请先同时选择崩溃日志与 dSYM。")
            return
        }

        result = nil
        status = .running("正在解析崩溃日志并调用 atos 进行符号化……")

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try CrashAnalysisService().analyze(crashLogURL: crashLogURL, dsymURL: dsymURL)
                }.value
                self.result = result
                self.status = .success("崩溃线程符号化完成。")
            } catch {
                self.result = nil
                self.status = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(outputText, forType: .string)
        status = .success("结果已复制到剪贴板。")
    }

    private func apply(url: URL, for target: InputTarget) {
        do {
            try validate(url: url, for: target)
            switch target {
            case .crashLog:
                crashLogURL = url
                result = nil
                status = .idle("崩溃日志已加载，等待开始分析。")
            case .dsym:
                dsymURL = url
                result = nil
                status = .idle("dSYM 已加载，等待开始分析。")
            }
        } catch {
            status = .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func validate(url: URL, for target: InputTarget) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw target == .crashLog ? CrashAnalyzerError.invalidCrashLog : CrashAnalyzerError.invalidDSYM
        }

        switch target {
        case .crashLog:
            let allowedExtensions = ["crash", "txt", "ips", "log", "json"]
            guard !isDirectory.boolValue, allowedExtensions.contains(url.pathExtension.lowercased()) else {
                throw CrashAnalyzerError.invalidCrashLog
            }
        case .dsym:
            guard isDirectory.boolValue, url.pathExtension.lowercased() == "dsym" else {
                throw CrashAnalyzerError.invalidDSYM
            }
        }
    }
}
