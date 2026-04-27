import SwiftUI

@main
struct CrashLocatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CrashLocator") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 780)
        }
        .defaultSize(width: 1180, height: 820)
    }
}
//1. CrashLocatorApp (@main)
//   └─ 2. AppDelegate.applicationDidFinishLaunching()
//        ├─ NSApp.setActivationPolicy(.regular)
//        └─ NSApp.activate(ignoringOtherApps: true)
//   └─ 3. WindowGroup 创建窗口
//        └─ 4. ContentView.init()
//             └─ 5. AnalysisViewModel.init()  (@StateObject 首次创建)
//                  ├─ crashLogURL = nil
//                  ├─ dsymURL = nil
//                  ├─ status = .idle(...)
//                  └─ result = nil
//             └─ 6. ContentView.body 首次求值
//                  ├─ header (标题 + 描述)
//                  ├─ FileDropZone × 2 (崩溃日志 + dSYM)
//                  ├─ controlBar (按钮 + 状态胶囊)
//                  ├─ summaryArea (两个 GroupBox, 此时显示 placeholder)
//                  └─ resultArea
//                       └─ 7. SelectableTextView.makeNSView()
//                            └─ 创建 NSScrollView + NSTextView，显示默认引导文字
