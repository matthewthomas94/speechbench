import Charts
import SwiftUI

struct TelemetryView: View {
    @EnvironmentObject private var telemetry: TelemetryMonitor

    var body: some View {
        let s = telemetry.latest
        let history = telemetry.history
        NavigationStack {
            List {
                Section {
                    MetricChart(
                        title: "CPU", unit: "%", latest: Fmt.num(s?.appCPU, 0, suffix: "% app"),
                        series: [
                            ("App", history.map { ($0.time, $0.appCPU) }),
                            ("System", history.compactMap { h in h.systemCPU.map { (h.time, $0) } }),
                        ])
                    MetricChart(
                        title: "App CPU power", unit: "W", latest: Fmt.num(s?.appPowerW, 2, suffix: " W"),
                        series: [("App CPU", history.compactMap { h in h.appPowerW.map { (h.time, $0) } })])
                    MetricChart(
                        title: "GPU time", unit: "%", latest: Fmt.num(s?.gpuPercent, 0, suffix: "%"),
                        series: [("GPU", history.compactMap { h in h.gpuPercent.map { (h.time, $0) } })])
                    MetricChart(
                        title: "App memory (footprint)", unit: "MB", latest: Fmt.mb(s?.footprintMB),
                        series: [("Footprint", history.compactMap { h in h.footprintMB.map { (h.time, $0) } })])
                } header: {
                    Text("Last 60 seconds")
                }

                Section("Power & thermals") {
                    row("App CPU power", Fmt.num(s?.appPowerW, 3, suffix: " W"))
                    row("App CPU energy (session)", Fmt.num(telemetry.sessionEnergyJ, 2, suffix: " J"))
                    row("Thermal state", telemetry.thermalState.label, color: telemetry.thermalState.color)
                    row("Battery", telemetry.batteryLevel < 0 ? "–" : "\(Int(telemetry.batteryLevel * 100))% · \(telemetry.batteryState.label)")
                    row("Low Power Mode", telemetry.lowPowerMode ? "On" : "Off")
                    Button("Reset session counters") { telemetry.resetSession() }
                }

                Section("CPU") {
                    row("App", "\(Fmt.num(s?.appCPU, 1, suffix: "%")) · \(Fmt.num(s?.appCores, 2)) cores busy")
                    row("System", Fmt.num(s?.systemCPU, 1, suffix: "%"))
                    if let perCore = s?.perCore, !perCore.isEmpty {
                        ForEach(Array(perCore.enumerated()), id: \.offset) { index, value in
                            HStack {
                                Text("Core \(index)").font(.caption.monospacedDigit()).frame(width: 52, alignment: .leading)
                                ProgressView(value: min(value, 100), total: 100)
                                Text(Fmt.num(value, 0, suffix: "%")).font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                Section("Memory") {
                    row("App footprint", Fmt.mb(s?.footprintMB))
                    row("App peak (session)", Fmt.mb(telemetry.sessionPeakMB))
                    row("Headroom before jetsam", Fmt.mb(s?.availableMB))
                    row("System in use", "\(Fmt.mb(s?.systemUsedMB)) of \(Fmt.mb(telemetry.physicalMemoryMB))")
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("iOS doesn't expose whole-device or Neural Engine power to apps. “App CPU power” is the kernel's per-process CPU energy estimate, so ANE-heavy runs will look cheaper than they are. For full power draw (CPU, GPU, ANE, display) record the app with Xcode Instruments › Power Profiler while running a test.")
                }
            }
            .navigationTitle("Telemetry")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(color)
        }
        .font(.callout)
    }
}

private struct MetricChart: View {
    struct Point: Identifiable {
        let series: String
        let time: Date
        let value: Double
        var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
    }

    let title: String
    let unit: String
    let latest: String
    let points: [Point]

    init(title: String, unit: String, latest: String, series: [(String, [(Date, Double)])]) {
        self.title = title
        self.unit = unit
        self.latest = latest
        points = series.flatMap { name, values in values.map { Point(series: name, time: $0.0, value: $0.1) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(latest).font(.subheadline.monospacedDigit())
            }
            Chart(points) { p in
                LineMark(x: .value("Time", p.time), y: .value(unit, p.value))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartLegend(Set(points.map(\.series)).count > 1 ? .visible : .hidden)
            .frame(height: 110)
        }
        .padding(.vertical, 4)
    }
}
