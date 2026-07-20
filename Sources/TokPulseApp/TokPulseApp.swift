import AppKit
import Combine
import SwiftUI
import TokPulseCore

@main
struct TokPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = SessionMonitor()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        observeMetrics()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TokPulse.StatusItem"
        guard let button = item.button else { return }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = "TokPulse — Codex output throughput"
        button.setAccessibilityIdentifier("TokPulse.StatusItem")
        button.setAccessibilityTitle("TokPulse Codex output throughput")
        statusItem = item
        updateStatusItem(metrics: monitor.metrics, answeringAgentCount: monitor.answeringAgentCount)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 360, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: DashboardContainerView(monitor: monitor)
        )
    }

    private func observeMetrics() {
        monitor.$metrics
            .combineLatest(monitor.$answeringAgentCount)
            .sink { [weak self] metrics, answeringAgentCount in
                self?.updateStatusItem(
                    metrics: metrics,
                    answeringAgentCount: answeringAgentCount
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(
        metrics: DashboardMetrics,
        answeringAgentCount: Int
    ) {
        guard let button = statusItem?.button else { return }

        let symbolName = answeringAgentCount > 0 ? "waveform" : "waveform.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image

        if metrics.activeAgentCount > 0 {
            button.title = "Avg \(MetricFormatting.tps(metrics.averageTPS)) · "
                + "Σ \(MetricFormatting.tps(metrics.totalTPS))"
            button.setAccessibilityValue(
                "Average \(MetricFormatting.tps(metrics.averageTPS)) and combined "
                    + "\(MetricFormatting.tps(metrics.totalTPS)) tokens per second"
            )
        } else {
            button.title = "Avg — · Σ —"
            button.setAccessibilityValue("No measured responses in the last ten minutes")
        }
    }
}

private struct DashboardContainerView: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        DashboardView(metrics: monitor.metrics, onRefresh: monitor.refreshNow)
    }
}
