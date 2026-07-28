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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = SessionMonitor()
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var dashboardHostingView: MenuHostingView<DashboardContainerView>?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        attachMenu()
        observeMetrics()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        dashboardHostingView?.synchronizeFrameWithContent()
        monitor.refreshNow()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TokPulse.StatusItem"
        guard let button = item.button else { return }

        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = "TokPulse — Codex output throughput"
        button.setAccessibilityIdentifier("TokPulse.StatusItem")
        button.setAccessibilityTitle("TokPulse Codex output throughput")
        statusItem = item
        updateStatusItem(metrics: monitor.metrics, answeringAgentCount: monitor.answeringAgentCount)
    }

    private func attachMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let cardItem = NSMenuItem()
        let hostingView = MenuHostingView(
            rootView: DashboardContainerView(monitor: monitor)
        )
        hostingView.sizingOptions = [.intrinsicContentSize]
        hostingView.synchronizeFrameWithContent()
        cardItem.view = hostingView
        menu.addItem(cardItem)
        dashboardHostingView = hostingView

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit TokPulse", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        if let quitImage = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil) {
            quitImage.isTemplate = true
            quitImage.size = NSSize(width: 16, height: 16)
            quitItem.image = quitImage
        }
        menu.addItem(quitItem)

        statusMenu = menu
        statusItem?.menu = menu
    }

    @objc
    private func quit() {
        NSApp.terminate(nil)
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
            button.setAccessibilityValue("No Agent has a completed sample in the last minute")
        }
    }
}

private struct DashboardContainerView: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        DashboardView(metrics: monitor.metrics, dailyMetrics: monitor.dailyMetrics)
    }
}

private final class MenuHostingView<Content: View>: NSHostingView<Content> {
    private static var menuWidth: CGFloat { 360 }

    private var isSynchronizingSize = false

    override var allowsVibrancy: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        synchronizeFrameWithContent()
    }

    func synchronizeFrameWithContent() {
        guard !isSynchronizingSize else { return }
        isSynchronizingSize = true
        defer { isSynchronizingSize = false }

        let contentHeight = max(1, ceil(fittingSize.height))
        guard abs(frame.height - contentHeight) > 0.5 || abs(frame.width - Self.menuWidth) > 0.5 else {
            return
        }

        frame.size = NSSize(width: Self.menuWidth, height: contentHeight)
        superview?.needsLayout = true
    }
}
