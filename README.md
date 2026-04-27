# CrashLocator

CrashLocator 是一个纯原生的 macOS 崩溃日志分析桌面应用，使用 Xcode + SwiftUI / AppKit 实现，不依赖 Python 或第三方工具。应用通过系统自带的 `dwarfdump` 与 `atos` 完成 dSYM UUID 校验和调用栈符号化，可同时用于 Swift 与 Objective-C 项目的崩溃定位。

## 功能特性

- 选择或拖拽崩溃日志文件：支持 `.crash`、`.txt`、`.ips`、`.json`
- 选择或拖拽 `.dSYM` 符号目录
- 自动解析标准文本日志、`.ips` JSON 以及业务侧自定义 JSON 包装日志中的崩溃类型、异常原因、崩溃线程、调用栈、Binary Images
- 使用 `dwarfdump --uuid` 读取 dSYM UUID；当崩溃日志缺少 UUID 时，自动按镜像名回退匹配
- 使用 `atos` 自动符号化崩溃线程调用栈
- 输出文件名、类名/模块名、方法名/函数名、代码行号
- 内置常见崩溃原因推断
- 底部原生文本结果区支持滚动、复制、全选

## 打开与运行

1. 使用 Xcode 打开 [CrashLocator.xcodeproj](/Users/mjt/Desktop/macCrashAnalysis/CrashLocator.xcodeproj)
2. 选择 `CrashLocator` Scheme
3. 直接运行即可

如果希望用命令行构建和启动：

```bash
./script/build_and_run.sh
```

## 使用方式

1. 选择或拖拽崩溃日志文件
2. 选择或拖拽对应的 `.dSYM` 目录
3. 点击“开始分析”
4. 查看顶部状态提示、摘要区精准定位结果以及底部完整符号化调用栈

## 运行效果说明

- UUID 匹配成功时，状态条会显示绿色成功提示，并输出符号化后的调用栈
- 崩溃日志缺少 UUID 时，会自动尝试按镜像名匹配所选 dSYM
- UUID 与镜像名都无法匹配时，状态条会显示红色错误提示，并阻止错误符号化
- 结果摘要区会突出显示：
  - 崩溃类型
  - 崩溃原因
  - 崩溃线程
  - 命中的 Binary Image 与 UUID
  - 文件名
  - 类名 / 模块名
  - 方法 / 函数名
  - 行号
  - 原因推断

## 说明

- 当前实现依赖 macOS 自带的 `xcrun dwarfdump` 与 `xcrun atos`
- App 默认按本地开发工具方式运行，不开启 App Sandbox，便于读取用户选择的文件并执行系统命令
