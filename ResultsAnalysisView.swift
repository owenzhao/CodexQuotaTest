import SwiftUI
import Charts
import AppKit

struct ResultsAnalysisView: View {
    @AppStorage("appLanguage") private var appLanguage = "en"
    @AppStorage("outputRoot") private var outputRoot = ""
    @State private var batches: [AnalysisBatch] = []
    @State private var selectedSessionIDs: Set<String> = []
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var planFilter = "latest"
    @State private var tierFilter = "all"
    @State private var modelFilter = "all"
    @State private var taskFilter = "all"
    @State private var searchText = ""
    @State private var includeInvalid = false
    @State private var chartMetric = "roundTime"
    @State private var selectedAttemptID: String?
    @State private var loadMessage = ""

    private var isChinese: Bool { appLanguage == "zh-Hans" }
    private func text(_ english: String, _ chinese: String) -> String { isChinese ? chinese : english }
    private var sessionIDs: [String] { Array(Set(batches.map(\.sessionID))).sorted() }
    private var batchesInRange: [AnalysisBatch] {
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        return batches.filter { batch in
            (selectedSessionIDs.isEmpty || selectedSessionIDs.contains(batch.sessionID)) &&
            batch.date >= Calendar.current.startOfDay(for: startDate) && batch.date < nextDay
        }
    }
    private var planOptions: [AnalysisPlanOption] {
        Dictionary(grouping: batchesInRange, by: \.planSignature).map { signature, values in
            let batch = values[0]
            return AnalysisPlanOption(signature: signature, tasks: batch.planTasks, rounds: batch.planRounds,
                concurrency: batch.planConcurrency, effort: batch.planEffort, suiteTag: batch.planSuiteTag,
                latestDate: values.map(\.date).max() ?? .distantPast)
        }.sorted { $0.latestDate > $1.latestDate }
    }
    private var activePlanSignature: String? {
        if planFilter == "all" { return nil }
        if planFilter == "latest" { return planOptions.first?.signature }
        return planFilter
    }
    private var visibleBatches: [AnalysisBatch] {
        batchesInRange.filter { batch in
            (activePlanSignature == nil || batch.planSignature == activePlanSignature) &&
            (tierFilter == "all" || batch.tier == tierFilter)
        }
    }
    private var comparablePlanBatches: [AnalysisBatch] {
        guard let activePlanSignature else { return [] }
        return batchesInRange.filter { $0.planSignature == activePlanSignature }
    }
    private var validBatches: [AnalysisBatch] {
        guard activePlanSignature != nil else { return [] }
        return visibleBatches.filter { $0.valid && $0.complete }
    }
    private var summaries: [AnalysisSummary] {
        let grouped = Dictionary(grouping: validBatches) { "\($0.model)|\($0.tier)|\($0.effort)" }
        return grouped.values.map(AnalysisSummary.init(batches:)).sorted {
            ($0.model, $0.tier, $0.effort) < ($1.model, $1.tier, $1.effort)
        }
    }
    private var fastInsights: [AnalysisFastInsight] {
        let valid = comparablePlanBatches.filter { $0.valid && $0.complete }
        let byRunAndModel = Dictionary(grouping: valid) { "\($0.sessionID)|\($0.model)|\($0.effort)" }
        let pairs = byRunAndModel.values.compactMap { values -> AnalysisFastPair? in
            guard let standard = values.first(where: { $0.tier == "default" }),
                  let fast = values.first(where: { $0.tier == "fast" }) else { return nil }
            return AnalysisFastPair(model: standard.model, standard: standard, fast: fast)
        }
        return Dictionary(grouping: pairs, by: \.model).map { model, pairs in
            AnalysisFastInsight(model: model, pairs: pairs)
        }.sorted { ($0.timeSavedPercent ?? -.infinity) > ($1.timeSavedPercent ?? -.infinity) }
    }
    private var fastestSummary: AnalysisSummary? {
        summaries.filter { $0.meanRoundSeconds != nil }.min {
            ($0.meanRoundSeconds ?? .infinity) < ($1.meanRoundSeconds ?? .infinity)
        }
    }
    private var lowestQuotaSummary: AnalysisSummary? {
        let values = summaries.filter { $0.meanFiveHourDelta != nil }
        guard values.count > 1, let low = values.map({ $0.meanFiveHourDelta! }).min() else { return nil }
        let indistinguishable = values.filter { ($0.meanFiveHourDelta ?? .infinity) - low < 1 }
        guard indistinguishable.count == 1 else { return nil }
        return indistinguishable[0]
    }
    private var lowestAPISummary: AnalysisSummary? {
        summaries.filter { $0.meanAPICost != nil }.min {
            ($0.meanAPICost ?? .infinity) < ($1.meanAPICost ?? .infinity)
        }
    }
    private var filteredAttempts: [AnalysisAttempt] {
        visibleBatches.flatMap { $0.attempts }.filter { attempt in
            guard includeInvalid || (attempt.valid && attempt.batchValid && attempt.batchComplete) else { return false }
            guard modelFilter == "all" || attempt.model == modelFilter else { return false }
            guard taskFilter == "all" || attempt.taskID == taskFilter else { return false }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty || [attempt.model, attempt.sessionName, attempt.taskName, attempt.status, attempt.effort]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
    }
    private var selectedAttempt: AnalysisAttempt? {
        guard let selectedAttemptID else { return nil }
        return filteredAttempts.first { $0.id == selectedAttemptID }
    }
    private var chartPoints: [AnalysisChartPoint] {
        validBatches.compactMap { batch in
            guard let value = chartValue(batch) else { return nil }
            return AnalysisChartPoint(batch: batch, value: value)
        }.sorted { $0.batch.date < $1.batch.date }
    }
    private var modelOptions: [String] { Array(Set(visibleBatches.map(\.model))).sorted() }
    private var taskOptions: [String] { Array(Set(visibleBatches.flatMap { $0.attempts.map(\.taskID) })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            filters.padding(.horizontal, 18).padding(.vertical, 12)
            if batches.isEmpty {
                ContentUnavailableView(text("No test results found", "没有找到测试结果"),
                    systemImage: "chart.bar.xaxis", description: Text(loadMessage.isEmpty ? text("Choose the folder containing your test logs.", "请选择测试日志所在文件夹。") : loadMessage))
            } else {
                TabView {
                    overviewTab.tabItem { Label(text("Answers", "结论"), systemImage: "sparkles") }
                    comparisonTab.tabItem { Label(text("Model comparison", "模型横向比较"), systemImage: "chart.bar.xaxis") }
                    historyTab.tabItem { Label(text("History", "模型历史趋势"), systemImage: "chart.xyaxis.line") }
                    detailsTab.tabItem { Label(text("Task details", "任务明细"), systemImage: "list.bullet.rectangle") }
                }.padding(.horizontal, 14)
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .onAppear(perform: loadResults)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 30, weight: .medium)).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(text("Results Analysis", "结果分析")).font(.system(size: 23, weight: .semibold))
                Text(outputRoot.isEmpty ? text("Log folder not selected", "尚未选择日志目录") : outputRoot)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Button(text("Choose folder…", "选择目录…"), action: chooseFolder)
            Button(text("Refresh", "刷新"), action: loadResults)
        }.padding(18)
    }

    private var filters: some View {
        HStack(spacing: 14) {
            Menu {
                Button(text("Select all runs", "全选运行记录")) { selectedSessionIDs = [] }
                Divider()
                ForEach(sessionIDs, id: \.self) { id in
                    let run = batches.first { $0.sessionID == id }
                    Toggle(isOn: Binding(
                        get: { selectedSessionIDs.isEmpty || selectedSessionIDs.contains(id) },
                        set: { selected in
                            if selectedSessionIDs.isEmpty { selectedSessionIDs = Set(sessionIDs) }
                            if selected { selectedSessionIDs.insert(id) } else { selectedSessionIDs.remove(id) }
                            if selectedSessionIDs.count == sessionIDs.count { selectedSessionIDs = [] }
                        })) {
                            Text("\(run.map { dateLabel($0.date) } ?? id) · \(run.map { displayName($0.model) } ?? id)")
                        }
                }
            } label: {
                Label(text("Runs: \(selectedSessionIDs.isEmpty ? sessionIDs.count : selectedSessionIDs.count)", "运行记录：\(selectedSessionIDs.isEmpty ? sessionIDs.count : selectedSessionIDs.count)"), systemImage: "calendar")
            }
            Picker(text("Test plan", "测试方案"), selection: $planFilter) {
                Text(text("Most recent comparable plan", "最近的可比方案")).tag("latest")
                Text(text("All plans (details only)", "全部方案（仅看明细）")).tag("all")
                ForEach(planOptions) { option in Text(planLabel(option)).tag(option.signature) }
            }.frame(minWidth: 250, idealWidth: 310)
            DatePicker(text("From", "开始"), selection: $startDate, displayedComponents: .date).labelsHidden()
            DatePicker(text("To", "结束"), selection: $endDate, displayedComponents: .date).labelsHidden()
            Picker(text("Tier", "速度模式"), selection: $tierFilter) {
                Text(text("All", "全部")).tag("all")
                Text("Standard").tag("default")
                Text("Fast").tag("fast")
            }.frame(width: 135)
            Spacer(minLength: 0)
        }
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            if activePlanSignature == nil {
                ContentUnavailableView(text("Choose one test plan for comparisons", "选择一个测试方案再进行比较"),
                    systemImage: "slider.horizontal.3",
                    description: Text(text("Model rankings mix different workloads when “All plans” is selected. Choose the latest or a specific comparable plan above.",
                                           "选择“全部方案”时工作负载不同，模型排名不可比。请在上方选择最近方案或指定一个可比方案。")))
            } else if validBatches.isEmpty {
                ContentUnavailableView(text("No complete valid batches for this plan", "此方案没有完整有效批次"),
                    systemImage: "checkmark.seal",
                    description: Text(text("Select more runs or widen the date range.", "请选择更多运行记录或扩大日期范围。")))
            } else {
                Text(text("Answers for the selected workload", "当前测试方案的结论")).font(.headline)
                answerCards
                HStack {
                    Text(text("Is Fast worth it?", "Fast 值不值得开？")).font(.headline)
                    Spacer()
                    Text(text("Matched valid Standard/Fast batches", "仅比较同一次运行中有效的 Standard/Fast 批次"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if fastInsights.isEmpty {
                    ContentUnavailableView(text("No matched Standard/Fast results", "没有可配对的 Standard/Fast 结果"),
                        systemImage: "arrow.left.arrow.right",
                        description: Text(text("Run both service tiers with the same workload to measure the time saved and extra quota use.",
                                               "使用相同方案完成 Standard 和 Fast 两种模式，才能计算节省时间和额度差异。")))
                        .frame(minHeight: 180)
                } else {
                    Table(fastInsights) {
                        TableColumn(text("Model", "模型")) { row in Text(displayName(row.model)).fontWeight(.medium) }.width(min: 140, ideal: 170)
                        TableColumn(text("Pairs", "配对批次")) { row in Text("\(row.pairs.count)") }.width(90)
                        TableColumn(text("Standard round", "Standard 每轮")) { row in Text(seconds(row.meanStandardSeconds)) }.width(145)
                        TableColumn(text("Fast round", "Fast 每轮")) { row in Text(seconds(row.meanFastSeconds)) }.width(135)
                        TableColumn(text("Time saved", "节省时间")) { row in Text(percent(row.timeSavedPercent)) }.width(120)
                        TableColumn(text("Quota use · 5-hour / weekly", "额度用量 · 5 小时 / 周")) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("5h: \(percentagePoints(row.meanStandardQuota)) → \(percentagePoints(row.meanFastQuota))")
                                Text("Week Δ: \(percentagePoints(row.meanWeeklyDifference))").font(.caption).foregroundStyle(.secondary)
                            }
                        }.width(220)
                        TableColumn(text("Quota difference", "额度差")) { row in Text(percentagePoints(row.meanQuotaDifference)) }.width(125)
                    }.frame(minHeight: 170, maxHeight: 270)
                    Text(fastVerdict)
                        .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    HStack(spacing: 6) {
                        Text(text("Current plan documentation lists Fast at 2.5× Standard allowance use; rounded snapshots may not show that rate precisely.",
                                  "当前官方说明将 Fast 的订阅额度消耗列为 Standard 的 2.5 倍；取整快照可能无法精确显示这一倍率。"))
                            .font(.caption).foregroundStyle(.secondary)
                        Link(text("Source", "来源"), destination: URL(string: "https://help.openai.com/en/articles/20001415-chatgpt-rate-card-enterprise-token-based-pricing")!)
                            .font(.caption)
                    }
                }
                Text(text("A quota snapshot has 1 percentage-point resolution. Small or zero differences do not prove equal consumption; judge Fast mainly by the observed time saved and treat quota deltas as approximate.",
                          "额度快照精度为 1 个百分点。差异小或显示为零都不能证明消耗相同；以实测节省时间为主，额度差只作近似参考。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.top, 12)
    }

    private var answerCards: some View {
        HStack(spacing: 12) {
            metricCard(text("Fastest observed", "实测最快"), fastestAnswer,
                       fastestSummary.map { text("\(seconds($0.meanRoundSeconds)) per round · \($0.roundCount) rounds · \(effortName($0.effort))", "每轮 \(seconds($0.meanRoundSeconds)) · \($0.roundCount) 轮 · \(effortName($0.effort))") } ?? text("Need valid round timings", "缺少有效轮次耗时"))
            metricCard(text("Lowest measured 5-hour use", "实测 5 小时额度最低"), quotaAnswer,
                       lowestQuotaSummary.map {
                           text("5h \(percentagePoints($0.meanFiveHourDelta)) · week \(percentagePoints($0.meanWeeklyDelta)) · API eq. \(usd($0.meanAPICost))/batch",
                                "5 小时 \(percentagePoints($0.meanFiveHourDelta)) · 周 \(percentagePoints($0.meanWeeklyDelta)) · API 等价 \(usd($0.meanAPICost))/批")
                       } ?? quotaNote)
            metricCard(text("Lowest API-equivalent cost", "API 等价金额最低"), apiCostAnswer,
                       lowestAPISummary.map { text("\(usd($0.meanAPICost)) per batch · estimate only", "每批 \(usd($0.meanAPICost)) · 仅供估算") } ?? text("Rates unavailable", "没有可用的单价"))
            metricCard(text("Fast trade-off", "Fast 的速度收益"), fastAnswer,
                       fastNote)
        }
    }

    private var fastestAnswer: String {
        guard let fastestSummary else { return text("Not enough valid data", "有效数据不足") }
        let distinctModels = Set(summaries.map(\.model))
        guard distinctModels.count > 1 else { return text("Only one model in range", "范围内只有一个模型") }
        return "\(displayName(fastestSummary.model)) · \(tierName(fastestSummary.tier))"
    }
    private var quotaAnswer: String {
        if let lowestQuotaSummary { return "\(displayName(lowestQuotaSummary.model)) · \(tierName(lowestQuotaSummary.tier))" }
        let distinctModels = Set(summaries.map(\.model))
        if distinctModels.count < 2 { return text("Need at least two models", "至少需要两个模型") }
        return text("No clear difference", "暂时分不出高下")
    }
    private var quotaNote: String {
        text("Available readings differ by less than 1 pp or are missing.", "可用读数差小于 1 个百分点，或额度数据缺失。")
    }
    private var apiCostAnswer: String {
        guard let lowestAPISummary else { return text("No priced models", "没有可计价的模型") }
        return "\(displayName(lowestAPISummary.model)) · \(tierName(lowestAPISummary.tier))"
    }
    private var fastAnswer: String {
        guard !fastInsights.isEmpty else { return text("No paired results", "没有配对结果") }
        let gains = fastInsights.compactMap(\.timeSavedPercent)
        guard !gains.isEmpty else { return text("Timing unavailable", "缺少耗时数据") }
        let average = gains.reduce(0, +) / Double(gains.count)
        return average >= 0
            ? text("Fast saves \(percent(average))", "Fast 平均节省 \(percent(average))")
            : text("Fast is \(percent(abs(average))) slower", "Fast 平均慢 \(percent(abs(average)))")
    }
    private var fastNote: String {
        guard !fastInsights.isEmpty else { return text("Needs valid Standard and Fast batches from the same run.", "需要同一次运行中有效的 Standard 和 Fast 批次。") }
        let quota = fastInsights.compactMap(\.meanQuotaDifference)
        let delta = quota.isEmpty ? nil : quota.reduce(0, +) / Double(quota.count)
        let week = fastInsights.compactMap(\.meanWeeklyDifference)
        let weekDelta = week.isEmpty ? nil : week.reduce(0, +) / Double(week.count)
        return text("\(fastInsights.reduce(0) { $0 + $1.pairs.count }) matched pairs · 5-hour Δ \(percentagePoints(delta)) · weekly Δ \(percentagePoints(weekDelta)) per batch.",
                    "\(fastInsights.reduce(0) { $0 + $1.pairs.count }) 组配对 · 5 小时变化 \(percentagePoints(delta)) · 周额度变化 \(percentagePoints(weekDelta))/批。")
    }
    private var fastVerdict: String {
        let gains = fastInsights.compactMap(\.timeSavedPercent)
        guard !gains.isEmpty else { return text("The matched batches do not have enough timing data to decide.", "配对批次缺少足够的耗时数据，暂时无法判断。") }
        let gain = gains.reduce(0, +) / Double(gains.count)
        let quota = fastInsights.compactMap(\.meanQuotaDifference)
        let delta = quota.isEmpty ? nil : quota.reduce(0, +) / Double(quota.count)
        let weekly = fastInsights.compactMap(\.meanWeeklyDifference)
        let weeklyDelta = weekly.isEmpty ? nil : weekly.reduce(0, +) / Double(weekly.count)
        if gain <= 0 {
            return text("Fast did not reduce average round time in these matched batches. With no measured speed gain and a 2.5× subscription allowance rate, this sample gives no reason to choose Fast.",
                        "这些配对批次里 Fast 没有缩短平均轮耗时。没有实测速度收益，而订阅额度按 2.5 倍消耗；这组样本没有显示出选择 Fast 的理由。")
        }
        if abs(delta ?? 0) >= 1 || abs(weeklyDelta ?? 0) >= 1 {
            return text("Fast saved \(percent(gain)) of round time. The snapshots show 5-hour Δ \(percentagePoints(delta)) and weekly Δ \(percentagePoints(weeklyDelta)) per batch; the documented subscription allowance rate is 2.5× Standard. Use Fast when that time saving is worth the higher allowance use.",
                        "Fast 平均节省 \(percent(gain)) 轮耗时。快照显示每批 5 小时变化 \(percentagePoints(delta))、周额度变化 \(percentagePoints(weeklyDelta))；官方订阅倍率为 Standard 的 2.5 倍。省下的时间值得更高额度消耗时，再开 Fast。")
        }
        return text("Fast saved \(percent(gain)) of round time, but the quota snapshots cannot resolve differences below 1 percentage point. Since the documented subscription allowance rate is 2.5× Standard, choose Fast when the time saving matters, not to save quota.",
                    "Fast 平均节省 \(percent(gain)) 轮耗时，但额度快照无法分辨低于 1 个百分点的差异。官方订阅额度倍率为 Standard 的 2.5 倍；Fast 适合优先节省时间的场景，不适合省额度。")
    }

    private var comparisonTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Only complete, valid model/tier batches are included. Token throughput is total output tokens divided by summed parallel round wall time.",
                      "仅纳入完整、有效的模型/速度模式批次。Token 吞吐量按总输出 Token ÷ 并行轮次耗时总和计算。"))
                .font(.caption).foregroundStyle(.secondary)
            if summaries.isEmpty {
                ContentUnavailableView(text("No complete valid batches in this range", "此范围内没有完整有效批次"),
                    systemImage: "checkmark.seal", description: Text(text("Include another run or widen the date range.", "请选择其他运行记录或扩大日期范围。")))
                    .frame(minHeight: 360)
            } else {
            Table(summaries) {
                TableColumn(text("Model", "模型")) { row in Text(displayName(row.model)).fontWeight(.medium) }.width(min: 125, ideal: 150)
                TableColumn(text("Tier / effort", "速度模式 / 档位")) { row in Text("\(tierName(row.tier)) · \(effortName(row.effort))") }.width(150)
                TableColumn(text("Batches / rounds", "批次 / 轮数")) { row in Text("\(row.batches.count) / \(row.roundCount)") }.width(110)
                TableColumn(text("Round / task time", "轮耗时 / 任务耗时")) { row in
                    VStack(alignment: .leading, spacing: 2) { Text(seconds(row.meanRoundSeconds)); Text(seconds(row.meanTaskSeconds)).font(.caption).foregroundStyle(.secondary) }
                }.width(125)
                TableColumn(text("First output", "首次输出")) { row in Text(seconds(row.meanFirstVisibleSeconds)) }.width(100)
                TableColumn(text("Input / cached", "输入 / 缓存")) { row in
                    VStack(alignment: .leading, spacing: 2) { Text(integer(row.inputTokens)); Text(integer(row.cachedTokens)).font(.caption).foregroundStyle(.secondary) }
                }.width(115)
                TableColumn(text("Output / reasoning", "输出 / 推理")) { row in
                    VStack(alignment: .leading, spacing: 2) { Text(integer(row.outputTokens)); Text(integer(row.reasoningTokens)).font(.caption).foregroundStyle(.secondary) }
                }.width(120)
                TableColumn(text("Output / non-reasoning tok/s", "输出 / 非推理 Token/s")) { row in
                    VStack(alignment: .leading, spacing: 2) { Text(rate(row.outputPerSecond)); Text(rate(row.nonReasoningPerSecond)).font(.caption).foregroundStyle(.secondary) }
                }.width(155)
                TableColumn(text("5-hour / weekly Δ", "5 小时 / 周额度变化")) { row in
                    VStack(alignment: .leading, spacing: 2) { Text(percentagePoints(row.meanFiveHourDelta)); Text(percentagePoints(row.meanWeeklyDelta)).font(.caption).foregroundStyle(.secondary) }
                }.width(145)
                TableColumn(text("API equiv. / batch", "API 等价 / 批次")) { row in Text(usd(row.meanAPICost)) }.width(125)
            }.frame(minHeight: 360)
            }
            Text(text("Quota values are percentage-point deltas from rounded snapshots; small differences can be hidden or shifted by the meter's resolution. API-equivalent cost uses the selected model's token counts and the rate snapshot shown below.",
                      "额度变化来自取整后的快照百分点；较小的差异可能被读数精度掩盖或延后。API 等价金额按该模型 Token 统计和下方单价快照计算。"))
                .font(.caption).foregroundStyle(.secondary)
            pricingNote
        }.padding(.top, 10)
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("Follow each model across runs", "按模型查看多次运行的变化")).font(.headline)
                Spacer()
                Picker(text("Metric", "指标"), selection: $chartMetric) {
                    Text(text("Mean round time", "平均轮耗时")).tag("roundTime")
                    Text(text("Output tokens/s", "输出 Token/s")).tag("throughput")
                    Text(text("Non-reasoning tokens/s", "非推理 Token/s")).tag("nonReasoning")
                    Text(text("5-hour quota change", "5 小时额度变化")).tag("quota")
                    Text(text("API-equivalent cost", "API 等价金额")).tag("apiCost")
                }.frame(width: 240)
            }
            Chart(chartPoints) { point in
                let series = "\(displayName(point.batch.model)) · \(tierName(point.batch.tier))"
                LineMark(x: .value(text("Run date", "运行日期"), point.batch.date),
                         y: .value(chartMetricTitle, point.value),
                         series: .value(text("Model and tier", "模型与速度模式"), series))
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value(text("Run date", "运行日期"), point.batch.date),
                          y: .value(chartMetricTitle, point.value))
                    .foregroundStyle(by: .value(text("Model and tier", "模型与速度模式"), series))
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxisLabel(text("Run date", "运行日期"))
            .chartYAxisLabel(chartMetric == "apiCost" ? "USD" : chartMetric == "quota" ? "percentage points" : chartMetric == "roundTime" ? "seconds" : "tokens / second")
            .frame(minHeight: 390)
            if chartPoints.isEmpty {
                ContentUnavailableView(text("No valid batches in this range", "此范围内没有有效批次"), systemImage: "chart.xyaxis.line")
            }
            Text(text("Each point is one complete model/service-tier batch. A line connects batches with the same model and tier; it does not imply continuous measurements between runs.",
                      "每个点代表一个完整的模型/速度模式批次。折线连接相同模型和速度模式的批次，不表示两次运行之间有连续测量。"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 12)
    }

    private var detailsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(text("Model", "模型"), selection: $modelFilter) {
                    Text(text("All models", "全部模型")).tag("all")
                    ForEach(modelOptions, id: \.self) { Text(displayName($0)).tag($0) }
                }.frame(width: 190)
                Picker(text("Task", "任务"), selection: $taskFilter) {
                    Text(text("All tasks", "全部任务")).tag("all")
                    ForEach(taskOptions, id: \.self) { Text(taskName($0)).tag($0) }
                }.frame(width: 230)
                Toggle(text("Include invalid / incomplete", "包含无效或未完成记录"), isOn: $includeInvalid).toggleStyle(.checkbox)
                Spacer()
                TextField(text("Search model, task, run…", "搜索模型、任务、运行记录…"), text: $searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 250)
            }
            Text(text("\(filteredAttempts.count) attempts · select a row to inspect token composition, timing, quota batch, and the saved response.",
                      "\(filteredAttempts.count) 次尝试 · 选择一行查看 Token 构成、耗时、额度批次和保存的回答。"))
                .font(.caption).foregroundStyle(.secondary)
            Table(filteredAttempts, selection: $selectedAttemptID) {
                TableColumn(text("Run", "运行")) { attempt in Text(dateLabel(attempt.startedAt ?? attempt.batchDate)).lineLimit(1) }.width(135)
                TableColumn(text("Model / tier", "模型 / 速度模式")) { attempt in
                    VStack(alignment: .leading, spacing: 2) { Text(displayName(attempt.model)); Text(tierName(attempt.tier)).font(.caption).foregroundStyle(.secondary) }
                }.width(135)
                TableColumn(text("Effort", "档位")) { attempt in Text(effortName(attempt.effort)) }.width(90)
                TableColumn(text("Task / round", "任务 / 轮次")) { attempt in
                    VStack(alignment: .leading, spacing: 2) { Text(taskName(attempt.taskID)).lineLimit(1); Text("R\(attempt.repeatNo)").font(.caption).foregroundStyle(.secondary) }
                }.width(175)
                TableColumn(text("Validity / status", "有效性 / 状态")) { attempt in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attempt.batchValid && attempt.valid ? text("Valid", "有效") : text("Invalid", "无效"))
                        Text(attempt.status).font(.caption).foregroundStyle(.secondary)
                    }
                }.width(115)
                TableColumn(text("Elapsed / first output", "运行 / 首次输出")) { attempt in
                    VStack(alignment: .leading, spacing: 2) { Text(seconds(attempt.elapsedSeconds)); Text(seconds(attempt.firstVisibleSeconds)).font(.caption).foregroundStyle(.secondary) }
                }.width(130)
                TableColumn(text("Input / cached", "输入 / 缓存")) { attempt in
                    VStack(alignment: .leading, spacing: 2) { Text(integer(attempt.inputTokens)); Text(integer(attempt.cachedTokens)).font(.caption).foregroundStyle(.secondary) }
                }.width(115)
                TableColumn(text("Output / reasoning", "输出 / 推理")) { attempt in
                    VStack(alignment: .leading, spacing: 2) { Text(integer(attempt.outputTokens)); Text(integer(attempt.reasoningTokens)).font(.caption).foregroundStyle(.secondary) }
                }.width(120)
                TableColumn(text("Output tok/s", "输出 Token/s")) { attempt in
                    let value = attempt.elapsedSeconds.flatMap { elapsed in elapsed > 0 ? Double(attempt.outputTokens) / elapsed : nil }
                    Text(rate(value))
                }.width(100)
                TableColumn(text("API equiv.", "API 等价金额")) { attempt in Text(usd(apiCost(attempt))) }.width(110)
            }.frame(minHeight: 300, maxHeight: 430)
            if let attempt = selectedAttempt {
                attemptDetail(attempt)
            }
        }.padding(.top, 10)
    }

    @ViewBuilder private var pricingNote: some View {
        HStack(spacing: 8) {
            Text(text("API rate snapshot: Oct 13, 2026. Standard input / cached input / output per million tokens; Fast is priced at 2× Standard. Estimates exclude tool-call fees and do not represent ChatGPT subscription charges.",
                      "API 单价快照：2026-10-13。按每百万输入/缓存输入/输出 Token 计价；Fast 按 Standard 的 2 倍计算。估算不含缓存写入费、工具调用费或长上下文倍率，也不代表 ChatGPT 订阅扣费。"))
                .font(.caption).foregroundStyle(.secondary)
            Link(text("API pricing", "API 定价来源"), destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
                .font(.caption)
        }
    }

    private func metricCard(_ title: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 19, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
            Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(11)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func attemptDetail(_ attempt: AnalysisAttempt) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(displayName(attempt.model)) · \(taskName(attempt.taskID)) · R\(attempt.repeatNo)").font(.headline)
                Spacer()
                Text(attempt.sessionName).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Text(text("Input \(integer(attempt.inputTokens)) (cached \(integer(attempt.cachedTokens)))", "输入 \(integer(attempt.inputTokens))（缓存 \(integer(attempt.cachedTokens))）"))
                Text(text("Output \(integer(attempt.outputTokens)) (reasoning \(integer(attempt.reasoningTokens)))", "输出 \(integer(attempt.outputTokens))（推理 \(integer(attempt.reasoningTokens))）"))
                Text(text("Elapsed \(seconds(attempt.elapsedSeconds))", "运行时间 \(seconds(attempt.elapsedSeconds))"))
                Text(text("First visible \(seconds(attempt.firstVisibleSeconds))", "首次可见输出 \(seconds(attempt.firstVisibleSeconds))"))
                Text(text("API estimate \(usd(apiCost(attempt)))", "API 金额估算 \(usd(apiCost(attempt)))"))
            }.font(.caption).foregroundStyle(.secondary)
            if let response = attempt.responseText, !response.isEmpty {
                DisclosureGroup(text("Saved response", "保存的回答")) {
                    ScrollView { Text(response).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6) }
                        .frame(maxHeight: 180).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var chartMetricTitle: String {
        switch chartMetric {
        case "throughput": return text("Output tokens/s", "输出 Token/s")
        case "nonReasoning": return text("Non-reasoning tokens/s", "非推理 Token/s")
        case "quota": return text("5-hour percentage points", "5 小时额度百分点")
        case "apiCost": return "USD"
        default: return text("Mean round seconds", "平均轮耗时（秒）")
        }
    }

    private func chartValue(_ batch: AnalysisBatch) -> Double? {
        let attempts = batch.attempts.filter(\.valid)
        let wallTime = batch.rounds.compactMap(\.wallSeconds).reduce(0, +)
        let output = attempts.reduce(0) { $0 + $1.outputTokens }
        let reasoning = attempts.reduce(0) { $0 + $1.reasoningTokens }
        switch chartMetric {
        case "throughput": return wallTime > 0 ? Double(output) / wallTime : nil
        case "nonReasoning": return wallTime > 0 ? Double(max(output - reasoning, 0)) / wallTime : nil
        case "quota": return batch.fiveHourDelta
        case "apiCost": return apiCost(batch)
        default:
            let times = batch.rounds.compactMap(\.wallSeconds)
            return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
        }
    }

    private func apiCost(_ batch: AnalysisBatch) -> Double? {
        guard AnalysisRates.values[batch.model] != nil else { return nil }
        return batch.attempts.filter(\.valid).reduce(0) { $0 + (apiCost($1) ?? 0) }
    }

    private func apiCost(_ attempt: AnalysisAttempt) -> Double? {
        guard let rates = AnalysisRates.values[attempt.model] else { return nil }
        let uncached = max(attempt.inputTokens - attempt.cachedTokens, 0)
        let standard = (Double(uncached) * rates.input + Double(attempt.cachedTokens) * rates.cached +
                        Double(attempt.outputTokens) * rates.output) / 1_000_000
        return attempt.tier == "fast" ? standard * 2 : standard
    }

    private func loadResults() {
        if outputRoot.isEmpty {
            if let data = try? Data(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("defaults.json")),
               let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                outputRoot = values["output_root"] as? String ?? ""
            }
        }
        guard !outputRoot.isEmpty else {
            batches = []
            loadMessage = text("Choose the folder containing your test logs.", "请选择测试日志所在文件夹。")
            return
        }
        do {
            let root = URL(fileURLWithPath: outputRoot, isDirectory: true)
            let folders = try FileManager.default.contentsOfDirectory(at: root,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            var loaded: [AnalysisBatch] = []
            for folder in folders {
                let file = folder.appendingPathComponent("session.json")
                guard let data = try? Data(contentsOf: file),
                      let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                loaded.append(contentsOf: parseBatches(session, folder: folder))
            }
            batches = loaded.sorted { $0.date < $1.date }
            selectedSessionIDs = []
            if let earliest = batches.map(\.date).min(), let latest = batches.map(\.date).max() {
                startDate = earliest
                endDate = latest
            }
            loadMessage = batches.isEmpty ? text("No session.json files were found in this folder.", "此目录下没有找到 session.json。") : ""
        } catch {
            batches = []
            loadMessage = error.localizedDescription
        }
    }

    private func parseBatches(_ session: [String: Any], folder: URL) -> [AnalysisBatch] {
        let sessionID = folder.path
        let sessionName = folder.lastPathComponent
        let config = session["config"] as? [String: Any] ?? [:]
        let sessionDate = parseDate(session["finished_at"] as? String ?? session["started_at"] as? String) ?? .distantPast
        let attempts = (session["attempts"] as? [[String: Any]] ?? []).map {
            AnalysisAttempt(json: $0, sessionID: sessionID, sessionName: sessionName,
                            batchDate: sessionDate, folder: folder, batchValid: false, batchComplete: false)
        }
        let attemptByID = Dictionary(uniqueKeysWithValues: attempts.map { ($0.id, $0) })
        return (session["groups"] as? [[String: Any]] ?? []).enumerated().map { index, group in
            let groupIDs = group["attempt_ids"] as? [String] ?? []
            let groupAttempts = groupIDs.compactMap { attemptByID[$0] }
            let valid = group["valid"] as? Bool ?? false
            let complete = group["complete"] as? Bool ?? false
            let model = group["model"] as? String ?? groupAttempts.first?.model ?? ""
            let tier = group["service_tier"] as? String ?? "default"
            let effort = groupAttempts.first?.effort ?? config["effort"] as? String ?? "unknown"
            let date = parseDate(group["started_at"] as? String) ?? sessionDate
            let configuredTasks = (config["tasks"] as? [String] ?? []).sorted()
            let configuredEffort = config["effort"] as? String ?? "unknown"
            let concurrency = config["concurrency"] as? Int ?? max(configuredTasks.count, 1)
            let expectedSamples = group["expected_samples"] as? Int ?? groupAttempts.count
            let roundsData = group["rounds"] as? [[String: Any]] ?? []
            let suiteHash = session["suite_sha256"] as? String ?? "legacy"
            let planSignature = [configuredTasks.joined(separator: ","), configuredEffort,
                                 String(concurrency), String(expectedSamples), suiteHash].joined(separator: "|")
            let planRounds = roundsData.count
            let suiteTag = String(suiteHash.prefix(6))
            let roundsByID = Dictionary(groupAttempts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let rounds = roundsData.map { round in
                let ids = round["attempt_ids"] as? [String] ?? []
                return AnalysisRound(repeatNo: round["repeat"] as? Int ?? 0,
                                     attempts: ids.compactMap { roundsByID[$0] })
            }
            let quota = group["quota_delta"] as? [String: Any]
            let codex = quota?["codex"] as? [String: Any]
            let before = (group["before"] as? [String: Any])?["pools"] as? [String: Any]
            let after = (group["after"] as? [String: Any])?["pools"] as? [String: Any]
            let beforeCodex = before?["codex"] as? [String: Any]
            let afterCodex = after?["codex"] as? [String: Any]
            let primary = codex?["primary"] as? [String: Any]
            let secondary = codex?["secondary"] as? [String: Any]
            let fiveBefore = (beforeCodex?["primary"] as? [String: Any])?["usedPercent"] as? Double
            let fiveAfter = (afterCodex?["primary"] as? [String: Any])?["usedPercent"] as? Double
            let weekBefore = (beforeCodex?["secondary"] as? [String: Any])?["usedPercent"] as? Double
            let weekAfter = (afterCodex?["secondary"] as? [String: Any])?["usedPercent"] as? Double
            let fiveDelta = (primary?["delta_pp"] as? Double) ?? {
                guard let fiveBefore, let fiveAfter else { return nil }
                return fiveAfter - fiveBefore
            }()
            let weekDelta = (secondary?["delta_pp"] as? Double) ?? {
                guard let weekBefore, let weekAfter else { return nil }
                return weekAfter - weekBefore
            }()
            let batchAttempts = groupAttempts.map {
                $0.withBatch(valid: valid, complete: complete, date: date)
            }
            return AnalysisBatch(id: "\(sessionID)|\(index)", sessionID: sessionID, sessionName: sessionName,
                date: date, model: model, tier: tier, effort: effort, planSignature: planSignature,
                planTasks: configuredTasks, planRounds: planRounds, planConcurrency: concurrency,
                planEffort: configuredEffort, planSuiteTag: suiteTag,
                valid: valid, complete: complete, expectedSamples: expectedSamples,
                fiveHourDelta: fiveDelta, weeklyDelta: weekDelta,
                fiveHourStart: fiveBefore, fiveHourEnd: fiveAfter,
                attempts: batchAttempts, rounds: rounds)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = text("Choose log folder", "选择日志目录")
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url.path
            loadResults()
        }
    }

    private func displayName(_ model: String) -> String {
        ["gpt-6.1-sol": "GPT-6.1 Sol", "gpt-6-sol": "GPT-6 Sol", "gpt-5.6-sol": "GPT-5.6 Sol",
         "gpt-6-luna": "GPT-6 Luna", "gpt-5.6-luna": "GPT-5.6 Luna"][model] ?? model
    }
    private func tierName(_ tier: String) -> String { tier == "fast" ? "Fast" : "Standard" }
    private func effortName(_ effort: String) -> String {
        ["low": "Light", "medium": "Medium", "high": "High", "sol_low_luna_medium": text("Model-specific", "按模型")][effort] ?? effort
    }
    private func taskName(_ id: String) -> String {
        let names: [String: (String, String)] = [
            "T1": ("SwiftUI dialog state diagnosis", "SwiftUI 弹窗状态诊断"),
            "T2": ("Modify code and run tests", "修改程序并运行测试"),
            "T3": ("Review string consistency", "字符串一致性审阅"),
            "T4": ("Find root cause in a long log", "长日志根因分析")]
        guard let name = names[id] else { return id }
        return text(name.0, name.1)
    }
    private func planLabel(_ option: AnalysisPlanOption) -> String {
        let tasks = option.tasks.joined(separator: ",")
        let effort = effortName(option.effort)
        return text("\(tasks) · \(option.rounds) rounds · max \(option.concurrency) parallel · \(effort) · \(option.suiteTag)",
                    "\(tasks) · \(option.rounds) 轮 · 并发 \(option.concurrency) · \(effort) · \(option.suiteTag)")
    }
    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = isChinese ? "yyyy-MM-dd HH:mm" : "MMM d, yyyy HH:mm"
        return formatter.string(from: date)
    }
    private func seconds(_ value: Double?) -> String { value.map { String(format: "%.1f s", $0) } ?? "—" }
    private func rate(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    private func percentagePoints(_ value: Double?) -> String { value.map { String(format: "%+.1f pp", $0) } ?? "—" }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    private func usd(_ value: Double?) -> String { value.map { String(format: "$%.4f", $0) } ?? "—" }
    private func integer(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: isChinese ? "zh_CN" : "en_US"))) }
    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct AnalysisBatch: Identifiable {
    let id: String
    let sessionID: String
    let sessionName: String
    let date: Date
    let model: String
    let tier: String
    let effort: String
    let planSignature: String
    let planTasks: [String]
    let planRounds: Int
    let planConcurrency: Int
    let planEffort: String
    let planSuiteTag: String
    let valid: Bool
    let complete: Bool
    let expectedSamples: Int
    let fiveHourDelta: Double?
    let weeklyDelta: Double?
    let fiveHourStart: Double?
    let fiveHourEnd: Double?
    let attempts: [AnalysisAttempt]
    let rounds: [AnalysisRound]
    var meanRoundSeconds: Double? {
        let times = rounds.compactMap(\.wallSeconds)
        return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
    }
}

private struct AnalysisPlanOption: Identifiable {
    let signature: String
    let tasks: [String]
    let rounds: Int
    let concurrency: Int
    let effort: String
    let suiteTag: String
    let latestDate: Date
    var id: String { signature }
}

private struct AnalysisFastPair {
    let model: String
    let standard: AnalysisBatch
    let fast: AnalysisBatch
    var timeSavedPercent: Double? {
        guard let standardTime = standard.meanRoundSeconds,
              let fastTime = fast.meanRoundSeconds, standardTime > 0 else { return nil }
        return (standardTime - fastTime) / standardTime * 100
    }
    var quotaDifference: Double? {
        guard let standardQuota = standard.fiveHourDelta, let fastQuota = fast.fiveHourDelta else { return nil }
        return fastQuota - standardQuota
    }
    var weeklyDifference: Double? {
        guard let standardQuota = standard.weeklyDelta, let fastQuota = fast.weeklyDelta else { return nil }
        return fastQuota - standardQuota
    }
}

private struct AnalysisFastInsight: Identifiable {
    let model: String
    let pairs: [AnalysisFastPair]
    var id: String { model }
    var meanStandardSeconds: Double? { average(pairs.compactMap { $0.standard.meanRoundSeconds }) }
    var meanFastSeconds: Double? { average(pairs.compactMap { $0.fast.meanRoundSeconds }) }
    var timeSavedPercent: Double? { average(pairs.compactMap(\.timeSavedPercent)) }
    var meanStandardQuota: Double? { average(pairs.compactMap { $0.standard.fiveHourDelta }) }
    var meanFastQuota: Double? { average(pairs.compactMap { $0.fast.fiveHourDelta }) }
    var meanQuotaDifference: Double? { average(pairs.compactMap(\.quotaDifference)) }
    var meanWeeklyDifference: Double? { average(pairs.compactMap(\.weeklyDifference)) }
    private func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

private struct AnalysisRound {
    let repeatNo: Int
    let attempts: [AnalysisAttempt]
    var wallSeconds: Double? {
        let dates = attempts.compactMap { $0.startedAt } + attempts.compactMap { $0.endedAt }
        guard let first = dates.min(), let last = dates.max(), last >= first else { return nil }
        return last.timeIntervalSince(first)
    }
}

private struct AnalysisAttempt: Identifiable {
    let id: String
    let sessionID: String
    let sessionName: String
    let batchDate: Date
    let model: String
    let taskID: String
    let taskName: String
    let repeatNo: Int
    let tier: String
    let effort: String
    let status: String
    let valid: Bool
    let batchValid: Bool
    let batchComplete: Bool
    let elapsedSeconds: Double?
    let firstVisibleSeconds: Double?
    let firstAnswerSeconds: Double?
    let inputTokens: Int
    let cachedTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let startedAt: Date?
    let endedAt: Date?
    let responseURL: URL?
    var responseText: String? { responseURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } }

    init(json: [String: Any], sessionID: String, sessionName: String, batchDate: Date,
         folder: URL, batchValid: Bool, batchComplete: Bool) {
        let id = json["attempt_id"] as? String ?? UUID().uuidString
        self.id = id
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.batchDate = batchDate
        model = json["model"] as? String ?? ""
        taskID = json["task"] as? String ?? ""
        taskName = json["task_name"] as? String ?? taskID
        repeatNo = json["repeat"] as? Int ?? 0
        tier = json["service_tier"] as? String ?? "default"
        effort = json["effort"] as? String ?? "unknown"
        status = json["status"] as? String ?? "unknown"
        valid = json["valid"] as? Bool ?? false
        self.batchValid = batchValid
        self.batchComplete = batchComplete
        elapsedSeconds = json["elapsed_seconds"] as? Double
        firstVisibleSeconds = json["first_visible_seconds"] as? Double
        firstAnswerSeconds = json["first_answer_seconds"] as? Double
        let total = ((json["tokens"] as? [String: Any])?["total"] as? [String: Any]) ?? [:]
        inputTokens = total["inputTokens"] as? Int ?? 0
        cachedTokens = total["cachedInputTokens"] as? Int ?? 0
        outputTokens = total["outputTokens"] as? Int ?? 0
        reasoningTokens = total["reasoningOutputTokens"] as? Int ?? 0
        startedAt = Self.parseDate(json["started_at"] as? String)
        endedAt = Self.parseDate(json["ended_at"] as? String)
        responseURL = folder.appendingPathComponent("answers", isDirectory: true).appendingPathComponent(id + ".md")
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    func withBatch(valid: Bool, complete: Bool, date: Date) -> AnalysisAttempt {
        AnalysisAttempt(id: id, sessionID: sessionID, sessionName: sessionName, batchDate: date,
            model: model, taskID: taskID, taskName: taskName, repeatNo: repeatNo, tier: tier, effort: effort,
            status: status, valid: self.valid, batchValid: valid, batchComplete: complete,
            elapsedSeconds: elapsedSeconds, firstVisibleSeconds: firstVisibleSeconds, firstAnswerSeconds: firstAnswerSeconds,
            inputTokens: inputTokens, cachedTokens: cachedTokens, outputTokens: outputTokens, reasoningTokens: reasoningTokens,
            startedAt: startedAt, endedAt: endedAt, responseURL: responseURL)
    }

    private init(id: String, sessionID: String, sessionName: String, batchDate: Date, model: String,
        taskID: String, taskName: String, repeatNo: Int, tier: String, effort: String, status: String,
        valid: Bool, batchValid: Bool, batchComplete: Bool, elapsedSeconds: Double?, firstVisibleSeconds: Double?,
        firstAnswerSeconds: Double?, inputTokens: Int, cachedTokens: Int, outputTokens: Int, reasoningTokens: Int,
        startedAt: Date?, endedAt: Date?, responseURL: URL?) {
        self.id = id; self.sessionID = sessionID; self.sessionName = sessionName; self.batchDate = batchDate
        self.model = model; self.taskID = taskID; self.taskName = taskName; self.repeatNo = repeatNo
        self.tier = tier; self.effort = effort; self.status = status; self.valid = valid
        self.batchValid = batchValid; self.batchComplete = batchComplete; self.elapsedSeconds = elapsedSeconds
        self.firstVisibleSeconds = firstVisibleSeconds; self.firstAnswerSeconds = firstAnswerSeconds
        self.inputTokens = inputTokens; self.cachedTokens = cachedTokens; self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens; self.startedAt = startedAt; self.endedAt = endedAt
        self.responseURL = responseURL
    }
}

private struct AnalysisSummary: Identifiable {
    let batches: [AnalysisBatch]
    var id: String { "\(model)|\(tier)|\(effort)" }
    var model: String { batches.first?.model ?? "" }
    var tier: String { batches.first?.tier ?? "default" }
    var effort: String { batches.first?.effort ?? "unknown" }
    private var attempts: [AnalysisAttempt] { batches.flatMap(\.attempts).filter(\.valid) }
    private var rounds: [AnalysisRound] { batches.flatMap(\.rounds) }
    var roundCount: Int { rounds.count }
    private var roundTimes: [Double] { rounds.compactMap(\.wallSeconds) }
    var meanRoundSeconds: Double? { roundTimes.isEmpty ? nil : roundTimes.reduce(0, +) / Double(roundTimes.count) }
    var meanTaskSeconds: Double? {
        let values = attempts.compactMap(\.elapsedSeconds)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var meanFirstVisibleSeconds: Double? {
        let values = attempts.compactMap(\.firstVisibleSeconds)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    var inputTokens: Int { attempts.reduce(0) { $0 + $1.inputTokens } }
    var cachedTokens: Int { attempts.reduce(0) { $0 + $1.cachedTokens } }
    var outputTokens: Int { attempts.reduce(0) { $0 + $1.outputTokens } }
    var reasoningTokens: Int { attempts.reduce(0) { $0 + $1.reasoningTokens } }
    var outputPerSecond: Double? {
        let wall = roundTimes.reduce(0, +)
        return wall > 0 ? Double(outputTokens) / wall : nil
    }
    var nonReasoningPerSecond: Double? {
        let wall = roundTimes.reduce(0, +)
        return wall > 0 ? Double(max(outputTokens - reasoningTokens, 0)) / wall : nil
    }
    var meanFiveHourDelta: Double? { mean(batches.compactMap(\.fiveHourDelta)) }
    var meanWeeklyDelta: Double? { mean(batches.compactMap(\.weeklyDelta)) }
    var meanAPICost: Double? {
        guard !batches.isEmpty, let rates = AnalysisRates.values[model] else { return nil }
        return batches.reduce(0) { sum, batch in
            let cost = batch.attempts.filter(\.valid).reduce(0.0) { value, attempt in
                let uncached = max(attempt.inputTokens - attempt.cachedTokens, 0)
                let standard = (Double(uncached) * rates.input + Double(attempt.cachedTokens) * rates.cached +
                                Double(attempt.outputTokens) * rates.output) / 1_000_000
                return value + (batch.tier == "fast" ? standard * 2 : standard)
            }
            return sum + cost
        } / Double(batches.count)
    }
    private func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
}

private struct AnalysisChartPoint: Identifiable {
    let batch: AnalysisBatch
    let value: Double
    var id: String { batch.id }
}

private struct AnalysisRates {
    let input: Double
    let cached: Double
    let output: Double
    static let values: [String: AnalysisRates] = [
        "gpt-6.1-sol": .init(input: 2, cached: 0.10, output: 10),
        "gpt-6-sol": .init(input: 2, cached: 0.20, output: 10),
        "gpt-5.6-sol": .init(input: 4, cached: 0.40, output: 20),
        "gpt-6-luna": .init(input: 0.10, cached: 0.01, output: 0.50),
        "gpt-5.6-luna": .init(input: 0.20, cached: 0.02, output: 1.20)
    ]
}
