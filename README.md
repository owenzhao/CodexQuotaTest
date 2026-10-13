# CodexQuotaTest

macOS 14+ 的 Codex 额度测试工具，当前源码对应 1.3.14。SwiftUI 界面位于 `BenchmarkApp.swift` 和 `ResultsAnalysisView.swift`，测试执行逻辑位于 `runner.py`。

“分析结果”窗口会读取日志目录下的历史 `session.json`，提供有效批次的模型横向比较、按日期查看的历史趋势，以及可按运行记录、模型、任务和文字筛选的尝试明细。额度变化以 5 小时和周窗口的百分点显示；API 等价金额使用代码内保存的单价快照计算，不代表订阅实际扣费。

## 构建

需要 Xcode 命令行工具、Python 3 和已安装的 Codex CLI。在项目目录运行 `python3 build.py`，应用及 ZIP 输出到 `build/`。运行 `python3 -m unittest test_runner` 可执行离线测试。

默认测试日志写入 `~/Documents/CodexQuotaTest/测试日志`，可在应用内调整。`suite.json` 包含测试提示词及作为测试材料的指令文本；它们是数据，并非本项目的开发指令。

此目录尚未包含开源许可证；发布前请确定许可证，并复核图标、测试数据和对 Codex CLI 的依赖。
