import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AnalysisViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(spacing: 16) {
                FileDropZone(
                    title: "崩溃日志",
                    subtitle: "支持 .crash / .txt / .ips / .json",
                    url: viewModel.crashLogURL,
                    chooseAction: viewModel.selectCrashLog,
                    clearAction: { viewModel.clear(.crashLog) },
                    onDrop: { viewModel.handleDrop(urls: $0, for: .crashLog) }
                )

                FileDropZone(
                    title: "dSYM",
                    subtitle: "请选择 .dSYM 文件夹",
                    url: viewModel.dsymURL,
                    chooseAction: viewModel.selectDSYM,
                    clearAction: { viewModel.clear(.dsym) },
                    onDrop: { viewModel.handleDrop(urls: $0, for: .dsym) }
                )
            }

            controlBar
            summaryArea
            resultArea
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CrashLocator")
                .font(.system(size: 30, weight: .semibold))
            Text("原生 macOS 崩溃日志分析工具，优先使用 UUID 校验，在缺少 UUID 时按镜像名回退匹配，并使用 atos 自动符号化 Swift / Objective-C 调用栈。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.analyze) {
                Label("开始分析", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canAnalyze)

            Button(action: viewModel.copyReport) {
                Label("复制结果", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.result == nil)

            Spacer()

            statusBadge
        }
    }

    private var summaryArea: some View {
        HStack(alignment: .top, spacing: 16) {
            GroupBox("崩溃摘要") {
                if let result = viewModel.result {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                        summaryRow(title: "异常类型", value: result.summary.exceptionType)
                        summaryRow(title: "异常原因", value: result.summary.reason ?? "未提供")
                        summaryRow(title: "崩溃线程", value: result.summary.crashedThread)
                        summaryRow(title: "命中镜像", value: result.summary.binaryImageName)
                        summaryRow(title: "镜像 UUID", value: result.summary.binaryImageUUID)
                        summaryRow(title: "匹配方式", value: result.summary.binaryImageMatchMethod)
                    }
                } else {
                    placeholder(text: "分析完成后，这里会显示崩溃类型、原因、线程与镜像匹配结果。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            GroupBox("精准定位") {
                if let result = viewModel.result {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                        summaryRow(title: "文件名", value: result.summary.fileName ?? "未定位")
                        summaryRow(title: "类名/模块名", value: result.summary.classOrModuleName ?? "未定位")
                        summaryRow(title: "方法/函数", value: result.summary.functionName)
                        summaryRow(title: "代码行号", value: result.summary.lineNumber.map(String.init) ?? "未定位")
                        summaryRow(title: "原因推断", value: result.summary.diagnosis)
                    }
                } else {
                    placeholder(text: "分析完成后，这里会突出显示最可能的问题文件、类名/模块名、方法名与代码行号。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var resultArea: some View {
        GroupBox("完整结果") {
            SelectableTextView(text: viewModel.outputText)
                .frame(maxWidth: .infinity, minHeight: 360)
                .padding(.top, 6)
        }
    }

    private var statusBadge: some View {
        Text(viewModel.status.message)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(statusForegroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(statusBackgroundColor)
            )
    }

    private var statusForegroundColor: Color {
        switch viewModel.status {
        case .idle:
            return .primary
        case .running:
            return .orange
        case .success:
            return .green
        case .failure:
            return .red
        }
    }

    private var statusBackgroundColor: Color {
        switch viewModel.status {
        case .idle:
            return Color.secondary.opacity(0.12)
        case .running:
            return Color.orange.opacity(0.12)
        case .success:
            return Color.green.opacity(0.12)
        case .failure:
            return Color.red.opacity(0.12)
        }
    }

    private func summaryRow(title: String, value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placeholder(text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }
}
