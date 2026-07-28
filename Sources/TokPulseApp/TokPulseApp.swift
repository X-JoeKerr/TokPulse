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
    private let statusBarPreferences = StatusBarPreferences()
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
        updateStatusItem(
            metrics: monitor.metrics,
            dailyMetrics: monitor.dailyMetrics,
            answeringAgentCount: monitor.answeringAgentCount,
            selection: statusBarPreferences.selection
        )
    }

    private func attachMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let cardItem = NSMenuItem()
        let hostingView = MenuHostingView(
            rootView: DashboardContainerView(
                monitor: monitor,
                statusBarPreferences: statusBarPreferences
            )
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
        Publishers.CombineLatest4(
            monitor.$metrics,
            monitor.$dailyMetrics,
            monitor.$answeringAgentCount,
            statusBarPreferences.$selection
        )
            .sink { [weak self] output in
                let (metrics, dailyMetrics, answeringAgentCount, selection) = output
                self?.updateStatusItem(
                    metrics: metrics,
                    dailyMetrics: dailyMetrics,
                    answeringAgentCount: answeringAgentCount,
                    selection: selection
                )
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem(
        metrics: DashboardMetrics,
        dailyMetrics: DailyMetrics,
        answeringAgentCount: Int,
        selection: StatusBarMetricSelection
    ) {
        guard let button = statusItem?.button else { return }

        let symbolName = answeringAgentCount > 0 ? "waveform" : "waveform.slash"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image

        let hasFreshSample = metrics.activeAgentCount > 0
        let fields = StatusBarMetric.allCases.compactMap { metric -> String? in
            guard selection.contains(metric) else { return nil }
            switch metric {
            case .average:
                return "Avg \(MetricFormatting.tps(metrics.averageTPS, available: hasFreshSample))"
            case .combined:
                return "Σ \(MetricFormatting.tps(metrics.totalTPS, available: hasFreshSample))"
            case .activeTime:
                return "Active Time \(MetricFormatting.activeTime(dailyMetrics.activeSeconds))"
            case .todayRate:
                let rate = MetricFormatting.tps(
                    dailyMetrics.tokensPerSecond,
                    available: dailyMetrics.activeSeconds > 0
                )
                return "Today Rate \(rate)"
            }
        }
        button.title = fields.joined(separator: " · ")
        button.setAccessibilityValue(
            fields.isEmpty
                ? "Status icon only"
                : fields.joined(separator: ", ")
        )
    }
}

private struct DashboardContainerView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var statusBarPreferences: StatusBarPreferences

    var body: some View {
        DashboardView(
            metrics: monitor.metrics,
            dailyMetrics: monitor.dailyMetrics,
            statusBarPreferences: statusBarPreferences
        )
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
