import AppKit
import SwiftUI
import TokPulseCore

struct DashboardView: View {
    let metrics: DashboardMetrics

    @State private var expandedSessionIDs: Set<String>

    init(metrics: DashboardMetrics) {
        self.metrics = metrics
        self._expandedSessionIDs = State(initialValue: Set(metrics.sessions.prefix(1).map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header
            self.summary
            Divider()
            self.sessions
            Divider()
            self.footer
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("TokPulse")
                .font(.headline)
            Spacer()
            Text("\(self.metrics.activeAgentCount) live")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(self.metrics.activeAgentCount) agents with a fresh sample")
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SummaryMetricView(
                    title: "Avg",
                    value: MetricFormatting.tps(
                        self.metrics.averageTPS,
                        available: self.metrics.activeAgentCount > 0),
                    accessibilityTitle: "Average tokens per second")
                SummaryMetricView(
                    title: "Σ Combined",
                    value: MetricFormatting.tps(
                        self.metrics.totalTPS,
                        available: self.metrics.activeAgentCount > 0),
                    accessibilityTitle: "Combined tokens per second")
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(MetricFormatting.window(self.metrics.windowSeconds)) freshness")
                Text("·")
                    .accessibilityHidden(true)
                Text("latest completed call")
                Spacer(minLength: 8)
                Text(
                    (self.metrics.activeAgentCount > 0
                        ? MetricFormatting.tokenCount(self.metrics.outputTokens)
                        : "—") + " latest tokens")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Label {
                Text(self.provenanceText)
            } icon: {
                Image(systemName: self.metrics.isEstimated ? "exclamationmark.triangle" : "checkmark.seal")
            }
            .font(.caption)
            .foregroundStyle(self.metrics.isEstimated ? Color.orange : Color.secondary)
            .accessibilityLabel("Metric provenance: \(self.provenanceText)")
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sessions")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(self.metrics.sessions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if self.metrics.sessions.isEmpty {
                Label("No Agent sample in the last minute", systemImage: "pause.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .accessibilityLabel("No Agent has a completed sample from the last minute")
            } else if self.metrics.sessions.count <= Self.visibleSessionLimit {
                VStack(spacing: Self.sessionSpacing) {
                    ForEach(self.metrics.sessions) { session in
                        SessionCardView(
                            session: session,
                            isExpanded: self.expansionBinding(for: session.id))
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: Self.sessionSpacing) {
                        ForEach(self.metrics.sessions) { session in
                            SessionCardView(
                                session: session,
                                isExpanded: self.expansionBinding(for: session.id))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: Self.scrollViewportHeight)
            }
        }
    }

    private static let sessionSpacing: CGFloat = 8
    private static let visibleSessionLimit = 5
    // Roughly five collapsed session cards plus inter-card spacing.
    private static let scrollViewportHeight: CGFloat = 5 * 62 + 4 * 8

    private var footer: some View {
        Text("Updated \(MetricFormatting.updatedTime(self.metrics.generatedAt))")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var provenanceText: String {
        self.metrics.isEstimated
            ? "Latest call · inferred timing included"
            : "Latest call · reported tokens and observed timing"
    }

    private func expansionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.expandedSessionIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    self.expandedSessionIDs.insert(id)
                } else {
                    self.expandedSessionIDs.remove(id)
                }
            })
    }
}

private struct SummaryMetricView: View {
    let title: String
    let value: String
    let accessibilityTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(self.value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("t/s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.accessibilityTitle)
        .accessibilityValue(self.value == "—" ? "Unavailable" : "\(self.value) tokens per second")
    }
}

private struct SessionCardView: View {
    let session: SessionMetrics
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: self.$isExpanded) {
            VStack(spacing: 0) {
                Divider()
                    .padding(.vertical, 8)
                ForEach(Array(self.session.agents.enumerated()), id: \.element.id) { index, agent in
                    AgentMetricRow(agent: agent)
                    if index < self.session.agents.count - 1 {
                        Divider()
                            .padding(.leading, 28)
                            .padding(.vertical, 7)
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(self.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(self.sourceLabel)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(self.sourceColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(self.sourceColor.opacity(0.14), in: Capsule())
                    }
                    Text(
                        "Avg \(MetricFormatting.tps(self.session.averageTPS, available: self.hasFreshSample)) · "
                            + "Σ \(MetricFormatting.tps(self.session.totalTPS, available: self.hasFreshSample)) t/s")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(self.session.activeAgentCount)/\(self.session.agents.count) live")
                    Text(
                        (self.hasFreshSample
                            ? MetricFormatting.tokenCount(self.session.outputTokens)
                            : "—") + " tok")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session \(self.title), source \(self.sourceLabel)")
            .accessibilityValue(
                "Average \(MetricFormatting.tps(self.session.averageTPS, available: self.hasFreshSample)), combined "
                    + "\(MetricFormatting.tps(self.session.totalTPS, available: self.hasFreshSample)) tokens per second, "
                    + "\(self.session.activeAgentCount) of \(self.session.agents.count) agents live")
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.5)
        }
    }

    private var hasFreshSample: Bool {
        self.session.activeAgentCount > 0
    }

    private var source: AgentSource {
        (self.session.agents.first(where: { $0.descriptor.kind == .root })
            ?? self.session.agents.first)?.descriptor.source ?? .codex
    }

    private var sourceLabel: String {
        switch self.source {
        case .codex: "CODEX"
        case .qoderCLI: "QODER"
        case .qoderQuest: "QODER QUEST"
        }
    }

    private var sourceColor: Color {
        self.source.isQoder ? Color.purple : Color.teal
    }

    private var title: String {
        guard let root = self.session.agents.first(where: { $0.descriptor.kind == .root })
            ?? self.session.agents.first
        else {
            return "Session \(MetricFormatting.shortenedID(self.session.id))"
        }

        if let workingDirectory = root.descriptor.workingDirectory {
            let projectName = URL(fileURLWithPath: workingDirectory).lastPathComponent
            if !projectName.isEmpty { return projectName }
        }
        if !root.descriptor.name.isEmpty { return root.descriptor.name }
        return "Session \(MetricFormatting.shortenedID(self.session.id))"
    }
}

private struct AgentMetricRow: View {
    let agent: AgentMetrics

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: self.agent.descriptor.kind == .root ? "person.fill" : "arrow.turn.down.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(self.agent.descriptor.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(self.kindLabel)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(self.agent.descriptor.model ?? "Model unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 4) {
                    if self.agent.hasFreshSample && self.agent.isEstimated {
                        Text("EST")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    Text(
                        "\(MetricFormatting.tps(self.agent.averageTPS, available: self.agent.hasFreshSample)) t/s last")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                Text(self.sampleDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.kindLabel) \(self.agent.descriptor.name)")
        .accessibilityValue(self.accessibilityValue)
    }

    private var kindLabel: String {
        self.agent.descriptor.kind == .root ? "ROOT" : "SUBAGENT"
    }

    private var sampleDetail: String {
        guard self.agent.hasFreshSample else { return "No sample in last minute" }
        return "\(MetricFormatting.tokenCount(self.agent.outputTokens)) tok · "
            + "\(MetricFormatting.activeTime(self.agent.activeSeconds)) call"
    }

    private var accessibilityValue: String {
        guard self.agent.hasFreshSample else { return "No completed sample in the last minute" }
        let model = self.agent.descriptor.model ?? "unavailable"
        let estimate = self.agent.isEstimated ? ", estimated" : ""
        return "Latest rate \(MetricFormatting.tps(self.agent.averageTPS)) tokens per second, "
            + "\(MetricFormatting.tokenCount(self.agent.outputTokens)) tokens, "
            + "\(MetricFormatting.activeTime(self.agent.activeSeconds)) call duration, model \(model)\(estimate)"
    }
}
