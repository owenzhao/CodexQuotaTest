import SwiftUI
import AppKit
import Combine

@main
struct BenchmarkApp: App {
    var body: some Scene {
        Window("Codex Quota Test", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1080, height: 800)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
        Window("Results Analysis", id: "analysis") {
            ResultsAnalysisView()
        }
        .defaultSize(width: 1420, height: 920)
    }
}

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("appLanguage") private var appLanguage = "en"
    var isChinese: Bool { appLanguage == "zh-Hans" }
    func text(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }
    let models = ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-6-luna", "gpt-5.6-luna"]
    let taskNames = [("T1", "SwiftUI dialog state diagnosis"), ("T2", "Modify code and run tests"),
                     ("T3", "Review string consistency"), ("T4", "Find root cause in a long log")]
    @State private var selectedModels: Set<String> = ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"]
    @State private var selectedTasks: Set<String> = ["T1", "T2", "T3", "T4"]
    @AppStorage("planRepeats") private var repeats = 4
    @AppStorage("planReasoningEffort") private var reasoningEffort = "sol_low_luna_medium"
    @AppStorage("planServiceTier") private var serviceTier = "mixed"
    @AppStorage("planConcurrency") private var concurrency = 4
    @State private var isolationConfirmed = false
    @State private var outputRoot = ""
    @State private var currentFolder: URL?
    @State private var statusFolder: URL?
    @State private var process: Process?
    @State private var isRunning = false
    @State private var operation = ""
    @State private var phase = "idle"
    @State private var message = "Check the environment, then start the test manually."
    @State private var localNoticeCode = ""
    @State private var environment: [String: Any] = [:]
    @State private var environmentCheckedForRun = false
    @State private var proxyMode = "auto"
    @State private var proxyURL = "http://127.0.0.1:7897"
    @State private var networkInfo: [String: Any] = [:]
    @State private var latestLimits: [String: Any] = [:]
    @State private var completed = 0
    @State private var planned = 48
    @State private var currentModel = ""
    @State private var currentTask = ""
    @State private var currentRepeat = 0
    @State private var elapsed = 0
    @State private var logLines: [String] = []
    @State private var lastLogMessage = ""
    @State private var taskRows: [[String: Any]] = []
    @State private var sessionCanResume = false
    @State private var recordedRounds = 4
    @State private var lastStatusTimestamp = ""
    @State private var exportBusy = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showRestartConfirmation = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var total: Int { selectedModels.count * selectedTasks.count * repeats }
    var resources: URL { Bundle.main.resourceURL! }
    var hasSession: Bool {
        guard let folder = currentFolder else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path)
    }
    var canStart: Bool {
        !isRunning && environmentCheckedForRun && !selectedModels.isEmpty && !selectedTasks.isEmpty && isolationConfirmed &&
            (serviceTier != "mixed" || repeats.isMultiple(of: 2))
    }
    var startDisabledReason: String? {
        if isRunning { return text("A test is already running.", "测试正在运行。") }
        if !environmentCheckedForRun { return text("Check the environment before starting.", "开始前请先检查环境。") }
        if selectedModels.isEmpty { return text("Select at least one model.", "至少选择一个模型。") }
        if selectedTasks.isEmpty { return text("Select at least one task.", "至少选择一项任务。") }
        if !isolationConfirmed { return text("Confirm that other Codex / Work tasks are paused.", "请确认已暂停同账户的其他 Codex / Work 任务。") }
        if serviceTier == "mixed" && !repeats.isMultiple(of: 2) {
            return text("Use an even repeat count to compare both service tiers.", "对比两种速度模式时，重复次数需为偶数。")
        }
        return nil
    }
    var displayedStatusMessage: String {
        switch localNoticeCode {
        case "proxyChanged": return text("Proxy settings changed. Check the environment again before starting.", "代理设置已变化，请重新检查环境后再开始。")
        case "pauseRequested": return text("Will pause after saving the current round.", "会在当前轮全部保存后暂停。")
        case "stopRequested": return text("Stop requested for all in-flight tasks.", "已请求停止所有在途任务。")
        default: break
        }
        switch phase {
        case "completed": return text("Test complete. Export the data logs for analysis.", "测试完成。请导出数据日志，交给分析者形成结论。")
        case "ready": return text("Environment check complete. No model was called.", "环境检查完成；尚未调用模型。")
        case "running": return text("The test is running. Progress and the current model are shown below.", "测试进行中；进度和当前模型见下方。")
        case "settling": return operation == "probe"
            ? text("Checking the CLI environment and quota readings.", "正在检查 CLI 环境和额度读数。")
            : text("Checking quota readings before continuing.", "正在核对额度读数。")
        case "retrying": return text("A quota read failed. Retrying without restarting the task.", "额度读取暂时失败；正在重试，不会重启任务。")
        case "paused": return text("The test is paused. See the saved logs for details.", "测试已暂停；详情请查看保存的日志。")
        case "error": return text("Environment check failed. See the saved diagnostics for details.", "环境检查失败；详情请查看保存的检测日志。")
        default: return text("Check the environment, then start the test manually.", "检查环境后，再手动开始测试。")
        }
    }
    var canResume: Bool {
        !isRunning && hasSession && sessionCanResume
    }
    var phaseTitle: String {
        switch phase {
        case "ready": return text("Environment ready", "环境已就绪")
        case "running": return text("Test running", "测试进行中")
        case "settling": return text("Waiting for quota readings", "等待额度读数稳定")
        case "retrying": return text("Retrying quota read", "自动重试额度读取")
        case "completed": return text("Test complete", "测试已完成")
        case "paused": return text("Test paused", "测试已暂停")
        case "error": return text("Action required", "需要处理")
        default: return text("Not started", "尚未启动")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "speedometer")
                    .font(.system(size: 36, weight: .medium)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(text("Codex Quota Test", "Codex 额度测试")).font(.system(size: 26, weight: .semibold))
                    Text(text("Runs tests independently · records data logs · draws no conclusions", "独立运行测试 · 记录数据日志 · 不生成分析结论"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker(text("Language", "语言"), selection: $appLanguage) {
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                }.frame(width: 160)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.system(.callout, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.blue.opacity(0.09), in: Capsule())
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox(text("Models", "测试模型")) {
                            VStack(alignment: .leading, spacing: 11) {
                                ForEach(models, id: \.self) { model in
                                    Toggle(displayName(model) + (model.hasSuffix("-luna") ? text(" (speed reference)", "（速度参考）") : ""), isOn: Binding(
                                        get: { selectedModels.contains(model) },
                                        set: {
                                            if $0 { selectedModels.insert(model) } else { selectedModels.remove(model) }
                                            UserDefaults.standard.set(Array(selectedModels), forKey: "planModels")
                                        }))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        }
                        .help(text("Model availability and supported effort settings are checked before a run.", "开始前会检查模型可用性和支持的推理档位。"))
                        GroupBox(text("Shared test tasks", "相同测试材料")) {
                            VStack(alignment: .leading, spacing: 11) {
                                ForEach(taskNames, id: \.0) { task in
                                    Toggle(localizedTaskName(task.0), isOn: Binding(
                                        get: { selectedTasks.contains(task.0) },
                                        set: {
                                            if $0 { selectedTasks.insert(task.0) } else { selectedTasks.remove(task.0) }
                                            UserDefaults.standard.set(Array(selectedTasks), forKey: "planTasks")
                                        }))
                                }
                                Divider()
                                Text(text("\(total) tasks total; each starts in a fresh session.", "共 \(total) 个任务，每个任务均从全新会话开始。"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(9)
                        }
                        GroupBox(text("Execution options", "执行选项")) {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(text("Service tier", "速度模式"), selection: $serviceTier) {
                                    Text(text("Standard only", "仅 Standard")).tag("default")
                                    Text(text("Fast only", "仅 Fast")).tag("fast")
                                    Text(text("Compare Standard and Fast", "对比 Standard 与 Fast")).tag("mixed")
                                }
                                Picker(text("Reasoning effort", "推理档位"), selection: $reasoningEffort) {
                                    Text(text("Model-specific", "按模型设置")).tag("sol_low_luna_medium")
                                    Text("Low").tag("low")
                                    Text("Medium").tag("medium")
                                    Text("High").tag("high")
                                }.help(text("Uses Light for Sol and Medium for Luna. The selected effort is recorded with each attempt.", "Sol 使用 Light、Luna 使用 Medium；每次尝试都会记录实际档位。"))
                                Stepper(text("Repeat each task \(repeats) times", "每项重复 \(repeats) 次"), value: $repeats,
                                        in: serviceTier == "mixed" ? 2...20 : 1...20,
                                        step: serviceTier == "mixed" ? 2 : 1)
                                if serviceTier == "mixed" {
                                    Text(text("Use an even repeat count to balance both tiers.", "重复次数需为偶数，才能平均分配两种速度模式。"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Stepper(text("Parallel tasks per round: \(concurrency)", "每轮并行任务：\(concurrency)"), value: $concurrency, in: 1...max(selectedTasks.count, 1))
                                    .help(text("Each round waits for all selected tasks before the next round starts.", "每轮会等待选中的任务全部完成，再开始下一轮。"))
                            }.padding(9)
                        }
                        GroupBox(text("Log location", "日志位置")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(outputRoot.isEmpty ? text("Loading…", "正在载入…") : outputRoot)
                                    .font(.caption).textSelection(.enabled).lineLimit(3)
                                Button(text("Change…", "更改位置…"), action: chooseOutputFolder)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        GroupBox(text("Proxy", "代理设置")) {
                            VStack(alignment: .leading, spacing: 9) {
                                Picker(text("Connection", "连接方式"), selection: $proxyMode) {
                                    Text(text("Use system proxy", "自动读取系统代理")).tag("auto")
                                    Text(text("Manual proxy", "手动代理")).tag("manual")
                                    Text(text("Inherit app environment", "继承应用启动环境")).tag("inherit")
                                    Text(text("Direct", "直连")).tag("direct")
                                }
                                if proxyMode == "manual" {
                                    TextField("http://127.0.0.1:7897", text: $proxyURL)
                                        .textFieldStyle(.roundedBorder)
                                        .help(text("HTTP/HTTPS/SOCKS5 URLs are supported. Authentication is not.", "支持 HTTP/HTTPS/SOCKS5 地址；不支持代理认证。"))
                                }
                                Button(text("View environment logs", "查看环境检测日志")) {
                                    let folder = URL(fileURLWithPath: outputRoot).appendingPathComponent("_环境检查")
                                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                                }
                            }.padding(8)
                        }
                        .help(text("Proxy choices affect only the CLI launched by this app. Direct mode does not disable VPN or TUN. Automatic mode uses the static system proxy when available; choose Manual for PAC.", "代理设置只影响本应用启动的 CLI，不会关闭 VPN 或 TUN。自动模式优先使用系统静态代理；PAC 请选手动地址。"))
                    }.disabled(isRunning).padding(.bottom, 10)
                }.frame(width: 340)
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Circle().fill(phase == "completed" ? .green : isRunning ? .blue : .secondary)
                                    .frame(width: 9, height: 9)
                                Text(phaseTitle).font(.headline)
                                Spacer()
                                if isRunning { ProgressView().controlSize(.small) }
                            }
                            Text(displayedStatusMessage).fixedSize(horizontal: false, vertical: true)
                            if hasSession || operation == "run" {
                                ProgressView(value: Double(completed), total: Double(max(planned, 1)))
                                HStack {
                                    Text(text("Progress: \(completed) / \(planned)", "任务进度：\(completed) / \(planned)"))
                                    Spacer()
                                    if elapsed > 0 { Text(text("Current task: \(elapsed)s", "当前题 \(elapsed) 秒")) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            if !currentModel.isEmpty {
                                Text(text("\(displayName(currentModel)) · Round \(currentRepeat) · \(currentTaskLabel)", "\(displayName(currentModel)) · 第 \(currentRepeat) 轮 · \(currentTaskLabel)"))
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    GroupBox(text("Account environment (read only; no model calls)", "账户环境（读取不调用模型）")) {
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Codex CLI")
                                Spacer()
                                Text(environment["cli_version"] as? String ?? text("Not checked", "尚未检查"))
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(text("Sign-in", "登录方式"))
                                Spacer()
                                Text(environment["login"] as? String ?? text("Not checked", "尚未检查")).foregroundStyle(.secondary)
                            }
                            if let checkedAt = (environment["checked_at"] as? String).flatMap(parseISODate) {
                                Text(text("Environment checked \(formatDate(checkedAt))", "环境检查于 \(formatDate(checkedAt))"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Divider()
                            HStack(spacing: 20) {
                                quotaView(text("5-hour quota", "5 小时剩余"), window: "primary")
                                quotaView(text("Weekly quota", "周额度剩余"), window: "secondary")
                            }
                            if let pool = mainPool(), let credits = pool["credits"] as? [String: Any],
                               let value = credits["balance"] as? String {
                                Text(text("Credit balance: \(formatCreditBalance(value))", "积分余额：\(formatCreditBalance(value))"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let observedAt = limitsObservedAt {
                                HStack(spacing: 4) {
                                    Text(text("Quota as of \(formatDate(observedAt))", "额度截至 \(formatDate(observedAt))"))
                                    if Date().timeIntervalSince(observedAt) > 15 * 60 {
                                        Text(text("· last check, may be outdated", "· 上次检查，可能已过期"))
                                            .foregroundStyle(.orange)
                                    }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(text("Pauses near quota limits; reset cards are never used automatically. Samples with a changed credit balance are invalidated.", "接近额度边界时暂停；不自动使用重置卡。积分余额变化的样本会作废。"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let lines = networkInfo["messages"] as? [String], !lines.isEmpty {
                                DisclosureGroup(text("Proxy and connection details", "代理与连接详情")) {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(localizedNetworkMessages(lines).enumerated()), id: \.offset) { _, line in
                                                Text(line).font(.system(size: 11)).textSelection(.enabled)
                                            }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 125)
                                }
                            }
                        }.padding(10)
                    }
                    GroupBox(text("Run history (one row per task)", "运行记录（每项一行）")) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if taskRows.isEmpty && logLines.isEmpty {
                                    Text(text("No history yet. Checking the environment does not start a model test.", "尚无记录。检查环境不会开始模型测试。"))
                                        .foregroundStyle(.secondary)
                                }
                                if !taskRows.isEmpty {
                                    ForEach(Array(taskRows.enumerated()), id: \.offset) { _, row in
                                        taskRecordView(row)
                                    }
                                    Text(text("Progress updates in place; retries show the attempt count. The full detailed log is preserved.", "进度在原行更新；重做显示尝试次数。原始详细日志仍完整保留。"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                        Text(line).font(.system(size: 12)).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.padding(9)
                        }.frame(maxWidth: .infinity, minHeight: 105, maxHeight: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(22)
            Divider()
            HStack(spacing: 10) {
                Button(text("Analyze results", "分析结果")) { openWindow(id: "analysis") }
                Button(text("Check environment", "检查环境"), action: checkEnvironment).disabled(isRunning)
                Toggle(text("I’ll pause other tasks", "我会暂停其他任务"), isOn: $isolationConfirmed)
                    .toggleStyle(.checkbox)
                    .disabled(isRunning)
                    .help(text("Pause other model chats and automated tasks on this account for the duration of the test. Progress is saved locally.", "测试期间请暂停同账户的其他模型聊天和自动任务。进度会保存在本机。"))
                Button(text("Start new test", "开始新测试"), action: beginRun).buttonStyle(.borderedProminent)
                    .disabled(!canStart).help(startDisabledReason ?? "")
                if canResume {
                    Button(text("Retry unfinished batches", "重测未完成批次")) { showRestartConfirmation = true }.disabled(!isolationConfirmed)
                }
                if isRunning && operation == "run" {
                    Button(text("Pause after this round", "完成当前轮后暂停")) { writeControl("pause") }
                    Button(text("Stop now", "立即停止"), role: .destructive) { writeControl("stop") }
                }
                Spacer()
                Button(text("Show log folder", "查看日志文件夹"), action: revealFolder).disabled(!hasSession)
                Button(text("Export data logs…", "导出数据日志…"), action: exportLogs).disabled(isRunning || !hasSession || exportBusy)
            }.padding(18)
            if let reason = startDisabledReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 10)
            }
        }
        .frame(minWidth: 1040, minHeight: 760)
        .onAppear(perform: loadDefaults)
        .onChange(of: proxyMode) { invalidateEnvironment() }
        .onChange(of: proxyURL) { invalidateEnvironment() }
        .onChange(of: serviceTier) { if serviceTier == "mixed" && !repeats.isMultiple(of: 2) { repeats = min(repeats + 1, 20) } }
        .onChange(of: selectedTasks.count) { concurrency = min(concurrency, max(selectedTasks.count, 1)) }
        .onChange(of: appLanguage) {
            logLines = []
            lastLogMessage = ""
            lastStatusTimestamp = ""
            loadStatus()
        }
        .onReceive(isRunning ? timer.eraseToAnyPublisher() : Empty<Date, Never>().eraseToAnyPublisher()) { _ in
            loadStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if isRunning && operation == "run" { writeControl("stop") }
        }
        .alert(text("Codex Quota Test", "Codex 额度测试"), isPresented: $showAlert) { Button(text("OK", "好"), role: .cancel) {} } message: {
            Text(alertMessage)
        }
        .confirmationDialog(text("Retry unfinished service tier batches", "重测未完成的速度模式批次"), isPresented: $showRestartConfirmation, titleVisibility: .visible) {
            Button(text("Retry", "确认重测"), action: resumeRun)
            Button(text("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(text("Completed batches are kept. Unfinished model and service tier batches restart from the beginning; their earlier progress is not included in new measurements. Original logs are kept. To start over, choose “Start new test”.", "已完整完成的批次保留。未完成的模型与速度模式批次会从头重跑，之前该批次的进度不会接入新计量结果；原始日志保留。要全新运行，请选择“开始新测试”。"))
        }
    }

    func displayName(_ model: String) -> String {
        ["gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-sol": "GPT-6 Sol", "gpt-6-luna": "GPT-6 Luna",
         "gpt-5.6-luna": "GPT-5.6 Luna", "gpt-5.6-sol": "GPT-5.6 Sol"][model] ?? model
    }
    func localizedTaskName(_ id: String) -> String {
        switch id {
        case "T1": return text("SwiftUI dialog state diagnosis", "SwiftUI 弹窗状态诊断")
        case "T2": return text("Modify code and run tests", "修改程序并运行测试")
        case "T3": return text("Review string consistency", "字符串一致性审阅")
        case "T4": return text("Find root cause in a long log", "长日志根因分析")
        default: return id
        }
    }
    func mainPool() -> [String: Any]? {
        let snapshot = !latestLimits.isEmpty ? latestLimits : environment["limits"] as? [String: Any] ?? [:]
        return (snapshot["pools"] as? [String: Any])?["codex"] as? [String: Any]
    }
    var limitsObservedAt: Date? {
        guard let value = (latestLimits.isEmpty ? environment["limits"] as? [String: Any] : latestLimits)?["observed_at"] as? String else { return nil }
        return parseISODate(value)
    }
    var currentTaskLabel: String {
        if currentTask.hasPrefix("本轮"), currentTask.hasSuffix("项并行"),
           let count = Int(currentTask.dropFirst(2).dropLast(3)) {
            return text("\(count) tasks in parallel", "\(count) 项并行")
        }
        return isChinese ? currentTask : text("Current work in progress", "当前任务进行中")
    }
    func formatCreditBalance(_ value: String) -> String {
        guard let amount = Double(value) else { return value }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        formatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        return formatter.string(from: NSNumber(value: amount)) ?? value
    }
    func parseISODate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    func localizedNetworkMessages(_ lines: [String]) -> [String] {
        guard !isChinese else { return lines }
        return lines.map { line in
            if line.hasPrefix("代理来源：") {
                let source = String(line.dropFirst("代理来源：".count))
                let translated = ["系统代理": "system proxy", "手动设置": "manual proxy", "明确直连": "direct connection",
                                  "应用启动环境": "app launch environment", "系统未设置代理；回退到应用启动环境": "system proxy unavailable; using app launch environment"][source] ?? source
                return "Proxy source: \(translated)"
            }
            if line.hasPrefix("注入CLI：") {
                let details = String(line.dropFirst("注入CLI：".count))
                    .replacingOccurrences(of: "；无代理变量（直连）", with: "; no proxy variables (direct)")
                return "Injected into CLI: \(details)"
            }
            if line.hasPrefix("代理端口 ") {
                return line.replacingOccurrences(of: "代理端口 ", with: "Proxy port ")
                    .replacingOccurrences(of: "：可达", with: ": reachable")
                    .replacingOccurrences(of: "：不可达", with: ": unreachable")
            }
            if line.hasPrefix("HTTPS探测配置：") { return line.replacingOccurrences(of: "HTTPS探测配置：", with: "HTTPS probe configuration: ") }
            if line.contains("排除简单主机名") { return "The system's simple-hostname exclusion was not translated; OpenAI's full domain names are unaffected." }
            if line.contains("握手探测未完成") { return "The handshake probe did not complete; HTTPS/WebSocket connectivity is unconfirmed." }
            if line.contains("握手探测收到HTTP") {
                return line.replacingOccurrences(of: "握手探测收到HTTP ", with: "Handshake probe returned HTTP ")
                    .replacingOccurrences(of: "；不代表正式WebSocket可用（本探测不发送登录凭据）。", with: "; this does not verify production WebSocket connectivity (no login credentials were sent).")
            }
            if line.hasPrefix("HTTP代理CONNECT隧道：") {
                return line.replacingOccurrences(of: "HTTP代理CONNECT隧道：", with: "HTTP proxy CONNECT tunnel: ")
            }
            if line.contains("未建立CONNECT隧道") { return "The HTTP proxy did not establish a CONNECT tunnel; it may have been bypassed by NO_PROXY." }
            if line.contains("匿名WebSocket升级成功") { return "An unauthenticated WebSocket upgrade succeeded; the production login session still needs a real task to confirm it." }
            if line.contains("握手探测未收到HTTP响应") {
                return line.replacingOccurrences(of: "握手探测未收到HTTP响应（curl退出码", with: "Handshake probe received no HTTP response (curl exit code ")
                    .replacingOccurrences(of: "）。", with: ").")
            }
            if line.contains("curl探测只验证") { return "The curl probe checks only its own route; the CLI route and production WebSocket compatibility remain unverified." }
            if line.contains("代理端口不可达") { return "The proxy port is unreachable; Codex was not started." }
            if line.contains("CLI账户额度读取成功") { return "The CLI quota read succeeded without a model call; this does not verify model WebSocket connectivity." }
            if line.contains("未调用模型") { return "No model was called." }
            return "Additional diagnostic details are available in the saved environment log."
        }
    }
    @ViewBuilder func quotaView(_ title: String, window: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let quota = mainPool()?[window] as? [String: Any], let used = quota["usedPercent"] as? Double {
                Text("\(Int(max(0, 100-used)))%")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                if let reset = quota["resetsAt"] as? Double {
                    Text(text("Resets \(formatDate(Date(timeIntervalSince1970: reset)))", "重置 \(formatDate(Date(timeIntervalSince1970: reset)))"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("—").font(.title2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func formatDate(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return formatter.string(from: value)
    }
    func loadDefaults() {
        guard outputRoot.isEmpty else { return }
        if let saved = UserDefaults.standard.stringArray(forKey: "planModels") { selectedModels = Set(saved) }
        if let saved = UserDefaults.standard.stringArray(forKey: "planTasks") { selectedTasks = Set(saved) }
        if let data = try? Data(contentsOf: resources.appendingPathComponent("defaults.json")),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            outputRoot = UserDefaults.standard.string(forKey: "outputRoot") ?? values["output_root"] as? String ?? ""
        }
        proxyMode = UserDefaults.standard.string(forKey: "proxyMode") ?? "auto"
        proxyURL = UserDefaults.standard.string(forKey: "proxyURL") ?? "http://127.0.0.1:7897"
        if let last = UserDefaults.standard.string(forKey: "lastRun"),
           FileManager.default.fileExists(atPath: last + "/session.json") {
            currentFolder = URL(fileURLWithPath: last)
            statusFolder = currentFolder
            loadStatus()
            if canResume { restorePlan(restoreProxy: false) }
        }
        loadSavedEnvironment()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func loadSavedEnvironment() {
        let file = URL(fileURLWithPath: outputRoot).appendingPathComponent("_环境检查/environment.json")
        guard let bytes = try? Data(contentsOf: file),
              let saved = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        environment = saved
        if let network = saved["network"] as? [String: Any] { networkInfo = network }
        if let limits = saved["limits"] as? [String: Any] {
            let savedDate = (limits["observed_at"] as? String).flatMap(parseISODate)
            let currentDate = (latestLimits["observed_at"] as? String).flatMap(parseISODate)
            if currentDate == nil {
                latestLimits = limits
            } else if let savedDate, let currentDate, savedDate > currentDate {
                latestLimits = limits
            }
        }
    }
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = text("Choose log location", "选择日志位置")
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url.path
            UserDefaults.standard.set(outputRoot, forKey: "outputRoot")
        }
    }
    func pythonURL() -> URL? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
    func checkEnvironment() {
        guard !isRunning, validateProxyURL() else { return }
        environmentCheckedForRun = false
        networkInfo = [:]
        UserDefaults.standard.set(proxyMode, forKey: "proxyMode")
        if proxyMode == "manual" { UserDefaults.standard.set(proxyURL, forKey: "proxyURL") }
        let folder = URL(fileURLWithPath: outputRoot).appendingPathComponent("_环境检查", isDirectory: true)
        launch("probe", folder: folder)
    }
    func beginRun() {
        guard canStart, validateProxyURL() else { return }
        let tag = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = URL(fileURLWithPath: outputRoot).appendingPathComponent("测试-" + tag + "-" + UUID().uuidString.prefix(6), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let config: [String: Any] = ["models": models.filter { selectedModels.contains($0) },
                "tasks": taskNames.filter { selectedTasks.contains($0.0) }.map { $0.0 },
                "repeats": repeats, "effort": reasoningEffort, "service_tier": serviceTier, "isolation_confirmed": true,
                "measurement_strategy": "complete_model_batch", "execution_mode": "parallel_tasks_per_round", "concurrency": concurrency,
                "proxy": ["mode": proxyMode, "url": proxyMode == "manual" ? proxyURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""]]
            let bytes = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: folder.appendingPathComponent("config.json"), options: .atomic)
            completed = 0; planned = total; logLines = []; taskRows = []; recordedRounds = repeats
            lastLogMessage = ""; currentModel = ""; elapsed = 0
            UserDefaults.standard.set(folder.path, forKey: "lastRun")
            launch("run", folder: folder)
        } catch { present(error.localizedDescription) }
    }
    func resumeRun() {
        guard !isRunning, isolationConfirmed, let folder = currentFolder else { return }
        restorePlan()
        launch("run", folder: folder, resume: true)
    }
    func restorePlan(restoreProxy: Bool = true) {
        guard let folder = currentFolder,
              let bytes = try? Data(contentsOf: folder.appendingPathComponent("config.json")),
              let plan = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        selectedModels = Set(plan["models"] as? [String] ?? models)
        selectedTasks = Set(plan["tasks"] as? [String] ?? taskNames.map { $0.0 })
        UserDefaults.standard.set(Array(selectedModels), forKey: "planModels")
        UserDefaults.standard.set(Array(selectedTasks), forKey: "planTasks")
        repeats = plan["repeats"] as? Int ?? 4
        reasoningEffort = plan["effort"] as? String ?? "high"
        serviceTier = plan["service_tier"] as? String ?? "default"
        concurrency = min(plan["concurrency"] as? Int ?? max(selectedTasks.count, 1), max(selectedTasks.count, 1))
        if restoreProxy {
            let proxy = plan["proxy"] as? [String: String] ?? ["mode": "inherit"]
            proxyMode = proxy["mode"] ?? "inherit"
            if let url = proxy["url"], !url.isEmpty { proxyURL = url }
        }
        planned = total
    }
    func invalidateEnvironment() {
        environmentCheckedForRun = false
        if !isRunning {
            phase = "idle"
            localNoticeCode = "proxyChanged"
            message = text("Proxy settings changed. Check the environment again. Retrying an old batch uses its original settings.", "代理设置已变化，请重新检查环境。重测旧批次会使用原计划的设置。")
        }
    }
    func validateProxyURL() -> Bool {
        guard proxyMode == "manual" else { return true }
        guard let url = URLComponents(string: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https", "socks5", "socks5h"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            present(text("Enter an HTTP/HTTPS/SOCKS5 proxy URL with a port. Usernames, passwords, and other URL parameters are not supported.", "请填写带端口的HTTP/HTTPS/SOCKS5代理地址，不支持用户名、密码或其他URL参数。"))
            return false
        }
        return true
    }
    func launch(_ command: String, folder: URL, resume: Bool = false) {
        guard let python = pythonURL() else {
            present(text("Python 3 was not found. This app requires Python 3.11 or later.", "未找到 Python 3。当前应用需要 Python 3.11 或更新版本。"))
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("process-output.jsonl")
            if !FileManager.default.fileExists(atPath: output.path) { FileManager.default.createFile(atPath: output.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            let task = Process()
            task.executableURL = python
            task.arguments = [resources.appendingPathComponent("runner.py").path, command,
                "--data-dir", folder.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
            if command == "run" {
                task.arguments! += ["--config", folder.appendingPathComponent("config.json").path]
                if resume { task.arguments!.append("--resume") }
            } else {
                task.arguments! += ["--proxy-mode", proxyMode, "--proxy-url", proxyMode == "manual" ? proxyURL : ""]
            }
            task.standardOutput = handle
            task.standardError = handle
            task.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, new in new }
            task.terminationHandler = { _ in
                try? handle.close()
                DispatchQueue.main.async {
                    loadStatus()
                    isRunning = false
                    process = nil
                    if phase == "running" || phase == "settling" {
                        phase = "paused"
                        message = text("The runner exited. Completed model batches are kept; resuming reruns all tasks for unfinished models.", "执行程序已退出。完整模型批次保留；继续时重跑未完成模型的全部任务。")
                    }
                }
            }
            statusFolder = folder
            if command == "run" { currentFolder = folder }
            operation = command
            localNoticeCode = ""
            phase = "settling"
            message = command == "probe" ? text("Reading environment; no model will be called.", "正在读取环境；不会调用模型。") : text("Establishing the quota baseline for an isolated test.", "正在建立独立测试的额度基线。")
            let oldBytes = try? Data(contentsOf: folder.appendingPathComponent("status.json"))
            let oldStatus = oldBytes.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            lastStatusTimestamp = oldStatus?["updated_at"] as? String ?? ""
            lastLogMessage = ""
            isRunning = true
            process = task
            try task.run()
        } catch {
            isRunning = false; process = nil; phase = "error"
            present(error.localizedDescription)
        }
    }
    func loadStatus() {
        loadTaskRows()
        guard let folder = statusFolder ?? currentFolder,
              let bytes = try? Data(contentsOf: folder.appendingPathComponent("status.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return }
        let timestamp = value["updated_at"] as? String ?? ""
        guard timestamp != lastStatusTimestamp else { return }
        lastStatusTimestamp = timestamp
        phase = value["phase"] as? String ?? phase
        if phase != "running" { localNoticeCode = "" }
        message = value["message"] as? String ?? message
        completed = value["completed"] as? Int ?? completed
        planned = value["total"] as? Int ?? planned
        currentModel = value["current_model"] as? String ?? currentModel
        currentTask = value["current_task"] as? String ?? currentTask
        currentRepeat = value["repeat"] as? Int ?? currentRepeat
        elapsed = value["elapsed_seconds"] as? Int ?? elapsed
        if let network = value["network"] as? [String: Any] { networkInfo = network }
        if let env = value["environment"] as? [String: Any] {
            environment = env
            latestLimits = env["limits"] as? [String: Any] ?? [:]
            if operation == "probe" && phase == "ready" { environmentCheckedForRun = true }
        }
        if let limits = value["limits"] as? [String: Any] { latestLimits = limits }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(displayedStatusMessage)"
        let identity = "\(phase)|\(message)"
        if lastLogMessage != identity { logLines.append(line); lastLogMessage = identity }
        if logLines.count > 120 { logLines.removeFirst(logLines.count - 120) }
    }
    func loadTaskRows() {
        guard let folder = currentFolder,
              let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
              let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        sessionCanResume = session["finished_at"] == nil && session["schema_version"] as? Int == 3
        let config = session["config"] as? [String: Any] ?? [:]
        recordedRounds = config["repeats"] as? Int ?? repeats
        var entries: [String: [String: Any]] = [:]
        var order: [String] = []
        for attempt in session["attempts"] as? [[String: Any]] ?? [] {
            let key = "\(attempt["model"] as? String ?? "")|\(attempt["task"] as? String ?? "")|\(attempt["repeat"] as? Int ?? 0)"
            if entries[key] == nil { order.append(key) }
            var row = attempt
            row["_attempts"] = (entries[key]?["_attempts"] as? Int ?? 0) + 1
            row["_inflight"] = false
            entries[key] = row
        }
        var inflight: [[String: Any]] = []
        if let bytes = try? Data(contentsOf: folder.appendingPathComponent("current-attempts.json")),
           let values = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            inflight = values["attempts"] as? [[String: Any]] ?? []
        } else if let bytes = try? Data(contentsOf: folder.appendingPathComponent("current-attempt.json")),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            inflight = [value]
        }
        for var current in inflight {
            let key = "\(current["model"] as? String ?? "")|\(current["task"] as? String ?? "")|\(current["repeat"] as? Int ?? 0)"
            // The same attempt can briefly exist in both files while it is saved.
            if entries[key]?["attempt_id"] as? String != current["attempt_id"] as? String {
                if entries[key] == nil { order.append(key) }
                current["_attempts"] = (entries[key]?["_attempts"] as? Int ?? 0) + 1
                current["_inflight"] = true
                entries[key] = current
            }
        }
        taskRows = order.compactMap { entries[$0] }
    }
    func taskRecordView(_ row: [String: Any]) -> some View {
        let model = row["model"] as? String ?? ""
        let task = row["task"] as? String ?? ""
        let name = localizedTaskName(task)
        let round = row["repeat"] as? Int ?? 0
        let attempts = row["_attempts"] as? Int ?? 1
        let inflight = row["_inflight"] as? Bool ?? false
        let state: String
        if inflight {
            if row["status"] as? String == "completed" { state = text("Done · waiting for round", "已结束 · 等待本轮") }
            else { state = phase == "settling" ? text("Settling", "结算中") : (phase == "paused" || phase == "error") ? text("Stopped", "已停止") : text("Running", "进行中") }
        } else if row["status"] as? String == "completed" {
            state = row["valid"] as? Bool == false ? text("Complete · batch invalid", "完成 · 批次作废") : text("Complete", "完成")
        } else { state = row["status"] as? String == "interrupted" ? text("Interrupted", "中断") : text("Not completed", "未完成") }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(text("Round \(round)/\(recordedRounds) · \((row["service_tier"] as? String) == "fast" ? "Fast" : "Standard") · \(name)", "第 \(round)/\(recordedRounds) 轮 · \((row["service_tier"] as? String) == "fast" ? "Fast" : "Standard") · \(name)"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(state).font(.caption).foregroundStyle(state == text("Complete", "完成") ? Color.green : Color.secondary)
            }
            HStack {
                Text(displayName(model) + " · " + ((row["effort"] as? String) == "low" ? "Light" : ((row["effort"] as? String) == "medium" ? "Medium" : "High")))
                    .font(.caption).foregroundStyle(.secondary)
                if attempts > 1 { Text(text("Attempt \(attempts)", "尝试 \(attempts) 次")).font(.caption).foregroundStyle(.orange) }
                Spacer()
                if let seconds = row["elapsed_seconds"] as? Double {
                    Text(text(String(format: "%.1f s", seconds), String(format: "%.1f 秒", seconds))).font(.caption).foregroundStyle(.secondary)
                } else if inflight { Text(text("\(elapsed) s", "\(elapsed) 秒")).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    func writeControl(_ action: String) {
        guard let folder = currentFolder else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["action": action])
            try data.write(to: folder.appendingPathComponent("control.json"), options: .atomic)
            localNoticeCode = action == "pause" ? "pauseRequested" : "stopRequested"
            message = action == "pause" ? text("Will pause after saving the current round. Incomplete service tier batches must be rerun.", "会在当前轮全部保存后暂停；未完成的速度模式批次需要重跑。") : text("Stop requested for all in-flight tasks. The current service tier batch will be invalidated.", "已请求停止所有在途任务；当前速度模式批次会作废。")
        } catch { present(error.localizedDescription) }
    }
    func revealFolder() {
        if let folder = currentFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }
    func exportLogs() {
        guard let folder = currentFolder, !isRunning else { return }
        let panel = NSSavePanel()
        panel.title = text("Export test data logs", "导出测试数据日志")
        panel.nameFieldStringValue = folder.lastPathComponent + ".zip"
        panel.directoryURL = URL(fileURLWithPath: outputRoot)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        exportBusy = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = ["-c", "-k", "--keepParent", folder.path, target.path]
        task.terminationHandler = { task in
            DispatchQueue.main.async {
                exportBusy = false
                if task.terminationStatus == 0 {
                    NSWorkspace.shared.activateFileViewerSelecting([target])
                } else { present(text("Log export failed. You can send the session.json file from the log folder.", "日志导出失败。可以直接发送日志文件夹内的 session.json。")) }
            }
        }
        do { try task.run() } catch { exportBusy = false; present(error.localizedDescription) }
    }
    func present(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
