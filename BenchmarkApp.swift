import SwiftUI
import AppKit
import Combine

@main
struct BenchmarkApp: App {
    var body: some Scene {
        Window("Codex 额度测试", id: "main") {
            ContentView()
        }
        .defaultSize(width: 1080, height: 800)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

struct ContentView: View {
    let models = ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-6-luna", "gpt-5.6-luna"]
    let taskNames = [("T1", "SwiftUI 弹窗状态诊断"), ("T2", "修改程序并运行测试"),
                     ("T3", "字符串一致性审阅"), ("T4", "长日志根因分析")]
    @State private var selectedModels: Set<String> = ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"]
    @State private var selectedTasks: Set<String> = ["T1", "T2", "T3", "T4"]
    @State private var repeats = 4
    @State private var isolationConfirmed = false
    @State private var outputRoot = ""
    @State private var currentFolder: URL?
    @State private var statusFolder: URL?
    @State private var process: Process?
    @State private var isRunning = false
    @State private var operation = ""
    @State private var phase = "idle"
    @State private var message = "先检查环境，再由你手动开始测试。"
    @State private var environment: [String: Any] = [:]
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
        !isRunning && !environment.isEmpty && !selectedModels.isEmpty && !selectedTasks.isEmpty && isolationConfirmed
    }
    var canResume: Bool {
        !isRunning && hasSession && sessionCanResume
    }
    var phaseTitle: String {
        switch phase {
        case "ready": return "环境已就绪"
        case "running": return "测试进行中"
        case "settling": return "等待额度读数稳定"
        case "retrying": return "自动重试额度读取"
        case "completed": return "测试已完成"
        case "paused": return "测试已暂停"
        case "error": return "需要处理"
        default: return "尚未启动"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "speedometer")
                    .font(.system(size: 36, weight: .medium)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 额度测试").font(.system(size: 26, weight: .semibold))
                    Text("独立运行测试 · 记录数据日志 · 不生成分析结论")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · Sol Light / Luna Medium · Standard/Fast")
                    .font(.system(.callout, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.blue.opacity(0.09), in: Capsule())
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 22) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GroupBox("测试模型") {
                            VStack(alignment: .leading, spacing: 11) {
                                ForEach(models, id: \.self) { model in
                                    Toggle(displayName(model) + (model.hasSuffix("-luna") ? "（速度参考）" : ""), isOn: Binding(
                                        get: { selectedModels.contains(model) },
                                        set: { value in if value { selectedModels.insert(model) } else { selectedModels.remove(model) } }))
                                }
                                Text("默认比较三个Sol的额度与耗时；Luna仅作速度参考，可另开少量轮次。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Sol 固定 Light（CLI low），Luna 固定 Medium；每次尝试的档位写入日志。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                        }
                        GroupBox("相同测试材料") {
                            VStack(alignment: .leading, spacing: 11) {
                                ForEach(taskNames, id: \.0) { task in
                                    Toggle(task.1, isOn: Binding(
                                        get: { selectedTasks.contains(task.0) },
                                        set: { value in if value { selectedTasks.insert(task.0) } else { selectedTasks.remove(task.0) } }))
                                }
                                Divider()
                                Stepper("每项重复 \(repeats) 次", value: $repeats, in: 2...20, step: 2)
                                Text("前 \(repeats / 2) 轮 Standard，后 \(repeats / 2) 轮 Fast；分别读取每种速度的整批额度。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("共 \(total) 个任务，每个任务均从全新会话开始。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("每个模型连续完成 \(selectedTasks.count * repeats) 项后再切换。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("每轮 \(selectedTasks.count) 项并行，全部结束后才开始下一轮。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(9)
                        }
                        GroupBox("日志位置") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(outputRoot.isEmpty ? "正在载入…" : outputRoot)
                                    .font(.caption).textSelection(.enabled).lineLimit(3)
                                Button("更改位置…", action: chooseOutputFolder)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        GroupBox("代理设置") {
                            VStack(alignment: .leading, spacing: 9) {
                                Picker("连接方式", selection: $proxyMode) {
                                    Text("自动读取系统代理").tag("auto")
                                    Text("手动代理").tag("manual")
                                    Text("继承应用启动环境").tag("inherit")
                                    Text("直连").tag("direct")
                                }
                                if proxyMode == "manual" {
                                    TextField("http://127.0.0.1:7897", text: $proxyURL)
                                        .textFieldStyle(.roundedBorder)
                                    Text("支持HTTP/HTTPS/SOCKS5地址；不支持用户名或密码。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text("自动模式：系统静态代理优先；未设置时继承应用环境。PAC请改用手动地址。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("设置只影响本应用启动的CLI；直连不会关闭VPN或TUN。")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("查看环境检测日志") {
                                    let folder = URL(fileURLWithPath: outputRoot).appendingPathComponent("_环境检查")
                                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                                }
                            }.padding(8)
                        }
                        Toggle("测试期间，我会暂停同账户其他 Codex / Work 任务。", isOn: $isolationConfirmed)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("进度由应用本地记录。测试过程中请不要让另一个模型聊天或自动任务继续运行。")
                            .font(.caption).foregroundStyle(.secondary)
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
                            Text(message).fixedSize(horizontal: false, vertical: true)
                            if hasSession || operation == "run" {
                                ProgressView(value: Double(completed), total: Double(max(planned, 1)))
                                HStack {
                                    Text("任务进度：\(completed) / \(planned)")
                                    Spacer()
                                    if elapsed > 0 { Text("当前题 \(elapsed) 秒") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            if !currentModel.isEmpty {
                                Text("\(displayName(currentModel)) · 第 \(currentRepeat) 轮 · \(currentTask)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    GroupBox("账户环境（读取不调用模型）") {
                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Codex CLI")
                                Spacer()
                                Text(environment["cli_version"] as? String ?? "尚未检查")
                                    .foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("登录方式")
                                Spacer()
                                Text(environment["login"] as? String ?? "尚未检查").foregroundStyle(.secondary)
                            }
                            Divider()
                            HStack(spacing: 20) {
                                quotaView("5 小时剩余", window: "primary")
                                quotaView("周额度剩余", window: "secondary")
                            }
                            if let pool = mainPool(), let credits = pool["credits"] as? [String: Any],
                               let value = credits["balance"] as? String {
                                Text("积分余额：\(value)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("接近额度边界时暂停；不自动使用重置卡。积分余额变化的样本会作废。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let lines = networkInfo["messages"] as? [String], !lines.isEmpty {
                                Divider()
                                Text("代理与连接检测").font(.caption.bold())
                                ScrollView {
                                    Text(lines.joined(separator: "\n"))
                                        .font(.system(size: 11)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 125)
                            }
                        }.padding(10)
                    }
                    GroupBox("运行记录（每项一行）") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if taskRows.isEmpty && logLines.isEmpty {
                                    Text("尚无记录。检查环境不会开始模型测试。")
                                        .foregroundStyle(.secondary)
                                }
                                if !taskRows.isEmpty {
                                    ForEach(Array(taskRows.enumerated()), id: \.offset) { _, row in
                                        taskRecordView(row)
                                    }
                                    Text("进度在原行更新；重做显示尝试次数。原始详细日志仍完整保留。")
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
                Button("检查环境", action: checkEnvironment).disabled(isRunning)
                Button("开始新测试", action: beginRun).buttonStyle(.borderedProminent).disabled(!canStart)
                if canResume {
                    Button("重测未完成批次") { showRestartConfirmation = true }.disabled(!isolationConfirmed)
                }
                if isRunning && operation == "run" {
                    Button("完成当前轮后暂停") { writeControl("pause") }
                    Button("立即停止", role: .destructive) { writeControl("stop") }
                }
                Spacer()
                Button("查看日志文件夹", action: revealFolder).disabled(!hasSession)
                Button("导出数据日志…", action: exportLogs).disabled(isRunning || !hasSession || exportBusy)
            }.padding(18)
        }
        .frame(minWidth: 1040, minHeight: 760)
        .onAppear(perform: loadDefaults)
        .onChange(of: proxyMode) { invalidateEnvironment() }
        .onChange(of: proxyURL) { invalidateEnvironment() }
        .onReceive(isRunning ? timer.eraseToAnyPublisher() : Empty<Date, Never>().eraseToAnyPublisher()) { _ in
            loadStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if isRunning && operation == "run" { writeControl("stop") }
        }
        .alert("Codex 额度测试", isPresented: $showAlert) { Button("好", role: .cancel) {} } message: {
            Text(alertMessage)
        }
        .confirmationDialog("重测未完成的速度模式批次", isPresented: $showRestartConfirmation, titleVisibility: .visible) {
            Button("确认重测", action: resumeRun)
            Button("取消", role: .cancel) {}
        } message: {
            Text("已完整完成的批次保留。未完成的模型与速度模式批次会从头重跑，之前该批次的进度不会接入新计量结果；原始日志保留。要全新运行，请选择“开始新测试”。")
        }
    }

    func displayName(_ model: String) -> String {
        ["gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-sol": "GPT-6 Sol", "gpt-6-luna": "GPT-6 Luna",
         "gpt-5.6-luna": "GPT-5.6 Luna", "gpt-5.6-sol": "GPT-5.6 Sol"][model] ?? model
    }
    func mainPool() -> [String: Any]? {
        let snapshot = !latestLimits.isEmpty ? latestLimits : environment["limits"] as? [String: Any] ?? [:]
        return (snapshot["pools"] as? [String: Any])?["codex"] as? [String: Any]
    }
    @ViewBuilder func quotaView(_ title: String, window: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if let quota = mainPool()?[window] as? [String: Any], let used = quota["usedPercent"] as? Double {
                Text("\(Int(max(0, 100-used)))%")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                if let reset = quota["resetsAt"] as? Double {
                    Text("重置 \(formatDate(Date(timeIntervalSince1970: reset)))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("—").font(.title2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func formatDate(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: value)
    }
    func loadDefaults() {
        guard outputRoot.isEmpty else { return }
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
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择日志位置"
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
        environment = [:]; networkInfo = [:]
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
                "repeats": repeats, "effort": "sol_low_luna_medium", "service_tier": "mixed", "isolation_confirmed": true,
                "measurement_strategy": "complete_model_batch", "execution_mode": "parallel_tasks_per_round",
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
        repeats = plan["service_tier"] as? String == "mixed" ? (plan["repeats"] as? Int ?? 4) : 4
        if restoreProxy {
            let proxy = plan["proxy"] as? [String: String] ?? ["mode": "inherit"]
            proxyMode = proxy["mode"] ?? "inherit"
            if let url = proxy["url"], !url.isEmpty { proxyURL = url }
        }
        planned = total
    }
    func invalidateEnvironment() {
        environment = [:]; networkInfo = [:]; latestLimits = [:]
        if !isRunning {
            phase = "idle"
            message = "代理设置已变化，请重新检查环境。重测旧批次会使用原计划的设置。"
        }
    }
    func validateProxyURL() -> Bool {
        guard proxyMode == "manual" else { return true }
        guard let url = URLComponents(string: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https", "socks5", "socks5h"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            present("请填写带端口的HTTP/HTTPS/SOCKS5代理地址，不支持用户名、密码或其他URL参数。")
            return false
        }
        return true
    }
    func launch(_ command: String, folder: URL, resume: Bool = false) {
        guard let python = pythonURL() else {
            present("未找到 Python 3。当前应用需要 Python 3.11 或更新版本。")
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
                        message = "执行程序已退出。完整模型批次保留；继续时重跑未完成模型的全部任务。"
                    }
                }
            }
            statusFolder = folder
            if command == "run" { currentFolder = folder }
            operation = command
            phase = "settling"
            message = command == "probe" ? "正在读取环境；不会调用模型。" : "正在建立独立测试的额度基线。"
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
        }
        if let limits = value["limits"] as? [String: Any] { latestLimits = limits }
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date()))  \(message)"
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
        let name = row["task_name"] as? String ?? taskNames.first(where: { $0.0 == task })?.1 ?? task
        let round = row["repeat"] as? Int ?? 0
        let attempts = row["_attempts"] as? Int ?? 1
        let inflight = row["_inflight"] as? Bool ?? false
        let state: String
        if inflight {
            if row["status"] as? String == "completed" { state = "已结束 · 等待本轮" }
            else { state = phase == "settling" ? "结算中" : (phase == "paused" || phase == "error") ? "已停止" : "进行中" }
        } else if row["status"] as? String == "completed" {
            state = row["valid"] as? Bool == false ? "完成 · 批次作废" : "完成"
        } else { state = row["status"] as? String == "interrupted" ? "中断" : "未完成" }
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("第 \(round)/\(recordedRounds) 轮 · \((row["service_tier"] as? String) == "fast" ? "Fast" : "Standard") · \(name)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(state).font(.caption).foregroundStyle(state == "完成" ? Color.green : Color.secondary)
            }
            HStack {
                Text(displayName(model) + " · " + ((row["effort"] as? String) == "low" ? "Light" : ((row["effort"] as? String) == "medium" ? "Medium" : "High")))
                    .font(.caption).foregroundStyle(.secondary)
                if attempts > 1 { Text("尝试 \(attempts) 次").font(.caption).foregroundStyle(.orange) }
                Spacer()
                if let seconds = row["elapsed_seconds"] as? Double {
                    Text(String(format: "%.1f 秒", seconds)).font(.caption).foregroundStyle(.secondary)
                } else if inflight { Text("\(elapsed) 秒").font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }
    func writeControl(_ action: String) {
        guard let folder = currentFolder else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["action": action])
            try data.write(to: folder.appendingPathComponent("control.json"), options: .atomic)
            message = action == "pause" ? "会在当前轮全部保存后暂停；未完成的速度模式批次需要重跑。" : "已请求停止所有在途任务；当前速度模式批次会作废。"
        } catch { present(error.localizedDescription) }
    }
    func revealFolder() {
        if let folder = currentFolder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }
    func exportLogs() {
        guard let folder = currentFolder, !isRunning else { return }
        let panel = NSSavePanel()
        panel.title = "导出测试数据日志"
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
                } else { present("日志导出失败。可以直接发送日志文件夹内的 session.json。") }
            }
        }
        do { try task.run() } catch { exportBusy = false; present(error.localizedDescription) }
    }
    func present(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}
