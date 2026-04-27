# CHANGELOG

- v0.1.0 2026-04-23 Codex: 初始实现 macOS 崩溃日志分析 APP，支持导入崩溃日志与 dSYM、UUID 强校验、基于 atos 的符号化定位与结果导出 (user-visible)
- v0.1.1 2026-04-24 Codex: 新增对业务侧自定义 JSON `.crash/.json` 日志的解析，并在缺少 UUID 时按镜像名回退匹配 dSYM，解决导入后误报“崩溃日志格式无法识别”问题 (user-visible)
- v0.1.2 2026-04-24 Codex: 修复同名多架构 dSYM 被误判为镜像名不匹配的问题，支持 fat dSYM 在缺少 UUID 的日志中继续符号化 (user-visible)
- v0.1.3 2026-04-24 Codex: 修复正则可选捕获组导致的数组越界崩溃，解决解析线程头时应用自身崩溃的问题 (user-visible)
- v0.1.4 2026-04-24 Codex: 新增 AppIcon 资源目录并应用用户提供的崩溃分析图标到 macOS 应用 (user-visible)
- v0.1.5 2026-04-24 Codex: 下移首页标题文案区域，优化顶部留白与视觉重心 (user-visible)
