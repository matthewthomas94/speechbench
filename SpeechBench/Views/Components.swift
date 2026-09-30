import SwiftUI

enum Fmt {
    static func num(_ v: Double?, _ digits: Int = 2, suffix: String = "") -> String {
        guard let v, v.isFinite else { return "–" }
        return String(format: "%.\(digits)f", v) + suffix
    }

    static func mb(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v >= 1024 ? String(format: "%.2f GB", v / 1024) : String(format: "%.0f MB", v)
    }

    static func seconds(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v < 1 ? String(format: "%.0f ms", v * 1000) : String(format: "%.2f s", v)
    }
}

/// Live strip pinned to the top of the test screens.
struct TelemetryHUD: View {
    @EnvironmentObject private var telemetry: TelemetryMonitor

    var body: some View {
        let s = telemetry.latest
        HStack(spacing: 0) {
            cell("App CPU", Fmt.num(s?.appCPU, 0, suffix: "%"))
            cell("Sys CPU", Fmt.num(s?.systemCPU, 0, suffix: "%"))
            cell("App CPU W", Fmt.num(s?.appPowerW))
            cell("GPU", Fmt.num(s?.gpuPercent, 0, suffix: "%"))
            cell("RAM", Fmt.mb(s?.footprintMB))
            cell("Thermal", telemetry.thermalState.label, color: telemetry.thermalState.color)
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func cell(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One-line summary of what a load or run cost.
struct CostLine: View {
    let cost: RunCost

    var body: some View {
        Text(
            "CPU \(Fmt.num(cost.avgCores)) cores · \(Fmt.num(cost.avgPowerW)) W · \(Fmt.num(cost.energyJ, 2, suffix: " J")) · GPU \(Fmt.seconds(cost.gpuSeconds)) · peak \(Fmt.mb(cost.peakFootprintMB))"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct LoadInfoView: View {
    let info: LoadInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(info.label).font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                if let d = info.downloadSeconds { stat("Download/verify", Fmt.seconds(d)) }
                stat("Load", Fmt.seconds(info.cost.wallSeconds))
                stat("RAM after", Fmt.mb(info.footprintAfterMB))
                stat("RAM added", Fmt.mb(info.cost.footprintGrowthMB))
            }
            CostLine(cost: info.cost)
        }
    }
}

func stat(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(value).font(.callout.monospacedDigit().weight(.semibold))
        Text(label).font(.caption2).foregroundStyle(.secondary)
    }
}

extension ProcessInfo.ThermalState {
    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .secondary
        }
    }
}
