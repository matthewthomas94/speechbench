import Foundation

/// What one model load or inference run cost the process.
struct RunCost {
    let wallSeconds: Double
    let cpuSeconds: Double
    /// Kernel CPU-energy estimate; excludes Neural Engine work.
    let energyJ: Double?
    let gpuSeconds: Double?
    let startFootprintMB: Double?
    let peakFootprintMB: Double?

    var avgCores: Double { wallSeconds > 0 ? cpuSeconds / wallSeconds : 0 }
    var avgPowerW: Double? { energyJ.map { wallSeconds > 0 ? $0 / wallSeconds : 0 } }
    var footprintGrowthMB: Double? {
        guard let s = startFootprintMB, let p = peakFootprintMB else { return nil }
        return p - s
    }
}

/// Brackets a unit of work: snapshots counters at init, polls memory footprint every
/// 10 ms to catch the peak, and reports deltas from `finish()`.
final class RunMeter {
    private let startUptime = ProcessInfo.processInfo.systemUptime
    private let startCPU = SystemMetrics.processCPUSeconds()
    private let startPower = SystemMetrics.processPower()
    private let startFootprint = SystemMetrics.processFootprintBytes()
    private let queue = DispatchQueue(label: "RunMeter.peak", qos: .userInitiated)
    private let timer: DispatchSourceTimer
    private var peak: UInt64 = 0

    init() {
        peak = startFootprint ?? 0
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if let f = SystemMetrics.processFootprintBytes(), f > peak { peak = f }
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    func finish() -> RunCost {
        let wall = ProcessInfo.processInfo.systemUptime - startUptime
        let cpu = SystemMetrics.processCPUSeconds() - startCPU
        let power = SystemMetrics.processPower()
        let peakBytes: UInt64 = queue.sync {
            timer.cancel()
            if let f = SystemMetrics.processFootprintBytes(), f > peak { peak = f }
            return peak
        }
        var energy: Double?, gpu: Double?
        if let power, let startPower {
            energy = Double(power.energyNJ &- startPower.energyNJ) / 1e9
            gpu = Double(power.gpuNS &- startPower.gpuNS) / 1e9
        }
        let mb = { (b: UInt64) in Double(b) / 1_048_576 }
        return RunCost(
            wallSeconds: wall, cpuSeconds: cpu, energyJ: energy, gpuSeconds: gpu,
            startFootprintMB: startFootprint.map(mb), peakFootprintMB: startFootprint == nil ? nil : mb(peakBytes))
    }
}
