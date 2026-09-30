import Foundation
import UIKit

struct TelemetrySample: Identifiable {
    let time: Date
    var id: Date { time }
    /// App CPU as % of the whole device's CPU capacity (0–100).
    let appCPU: Double
    /// App CPU expressed as fully-busy cores (1.0 = one core pegged).
    let appCores: Double
    let systemCPU: Double?
    let perCore: [Double]
    let appPowerW: Double?
    let gpuPercent: Double?
    let footprintMB: Double?
    let availableMB: Double
    let systemUsedMB: Double?
}

/// Samples process + system counters twice a second and keeps a rolling minute of history.
@MainActor
final class TelemetryMonitor: ObservableObject {
    static let interval: TimeInterval = 0.5
    static let historyLength = 120

    @Published private(set) var history: [TelemetrySample] = []
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var sessionEnergyJ: Double = 0
    @Published private(set) var sessionPeakMB: Double = 0

    var latest: TelemetrySample? { history.last }
    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    let physicalMemoryMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576

    private var timer: Timer?
    private var lastUptime = ProcessInfo.processInfo.systemUptime
    private var lastCPU = SystemMetrics.processCPUSeconds()
    private var lastPower = SystemMetrics.processPower()
    private var lastTicks = SystemMetrics.coreTicks()
    private let logToConsole = ProcessInfo.processInfo.arguments.contains("-logTelemetry")

    func start() {
        guard timer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        print("[telemetry] energy counter: \(lastPower == nil ? "unavailable" : "ok"); per-core CPU: \(lastTicks == nil ? "unavailable" : "ok")")
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func resetSession() {
        sessionEnergyJ = 0
        sessionPeakMB = 0
    }

    private func sample() {
        let uptime = ProcessInfo.processInfo.systemUptime
        let dt = uptime - lastUptime
        guard dt > 0 else { return }

        let cpu = SystemMetrics.processCPUSeconds()
        let appCores = max(0, cpu - lastCPU) / dt

        let power = SystemMetrics.processPower()
        var appPowerW: Double?
        var gpuPercent: Double?
        if let power, let lastPower {
            let joules = Double(power.energyNJ &- lastPower.energyNJ) / 1e9
            appPowerW = joules / dt
            sessionEnergyJ += joules
            gpuPercent = Double(power.gpuNS &- lastPower.gpuNS) / (dt * 1e9) * 100
        }

        let ticks = SystemMetrics.coreTicks()
        var perCore: [Double] = []
        var systemCPU: Double?
        if let ticks, let lastTicks, ticks.count == lastTicks.count {
            var busy: UInt64 = 0, total: UInt64 = 0
            for (now, before) in zip(ticks, lastTicks) {
                let b = now.busy &- before.busy, t = now.total &- before.total
                busy += b
                total += t
                perCore.append(t > 0 ? Double(b) / Double(t) * 100 : 0)
            }
            systemCPU = total > 0 ? Double(busy) / Double(total) * 100 : nil
        }

        let footprintMB = SystemMetrics.processFootprintBytes().map { Double($0) / 1_048_576 }
        if let footprintMB { sessionPeakMB = max(sessionPeakMB, footprintMB) }

        let s = TelemetrySample(
            time: Date(),
            appCPU: appCores / Double(coreCount) * 100,
            appCores: appCores,
            systemCPU: systemCPU,
            perCore: perCore,
            appPowerW: appPowerW,
            gpuPercent: gpuPercent,
            footprintMB: footprintMB,
            availableMB: Double(SystemMetrics.availableBytes()) / 1_048_576,
            systemUsedMB: SystemMetrics.systemUsedBytes().map { Double($0) / 1_048_576 }
        )
        history.append(s)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }

        let device = UIDevice.current
        batteryLevel = device.batteryLevel
        batteryState = device.batteryState
        thermalState = ProcessInfo.processInfo.thermalState
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        if logToConsole {
            func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "-" }
            print("[telemetry] appCPU=\(f(s.appCPU))% cores=\(f(s.appCores)) sysCPU=\(f(s.systemCPU))% appW=\(f(s.appPowerW)) gpu=\(f(s.gpuPercent))% footprintMB=\(f(s.footprintMB)) availMB=\(f(s.availableMB)) sysUsedMB=\(f(s.systemUsedMB)) thermal=\(thermalState.rawValue)")
        }

        lastUptime = uptime
        lastCPU = cpu
        lastPower = power
        lastTicks = ticks
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

extension UIDevice.BatteryState {
    var label: String {
        switch self {
        case .unplugged: "On battery"
        case .charging: "Charging"
        case .full: "Full"
        case .unknown: "Unknown"
        @unknown default: "Unknown"
        }
    }
}
