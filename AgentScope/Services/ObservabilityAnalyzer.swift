import Foundation

/// Stateless analyzer for session observability metrics.
struct ObservabilityAnalyzer {

    /// Compute observability data for a session from its OTEL spans
    static func computeObservability(
        turnDurations: [TurnDuration],
        errorDetails: [SessionErrorDetail],
        parallelToolGroups: [ParallelToolGroup],
        otelSpans: [OtelSpan]
    ) -> SessionObservability {
        let durations = turnDurations.map(\.durationMs)
        let ttfts = otelSpans.compactMap(\.ttftMs)

        // Vendor distribution from chat spans
        var vendorDist: [String: Int] = [:]
        var agentCount = 0
        for span in otelSpans {
            if span.operationName == "chat", let model = span.effectiveModel {
                let vendor = ModelVendor.from(model: model).rawValue
                vendorDist[vendor, default: 0] += 1
            }
            if span.operationName == "invoke_agent" {
                agentCount += 1
            }
        }

        return SessionObservability(
            medianTurnDurationMs: median(durations),
            maxTurnDurationMs: durations.max(),
            medianTtftMs: median(ttfts),
            errorClassifications: errorDetails.map(\.classification),
            parallelToolCallCount: parallelToolGroups.count,
            maxParallelDegree: parallelToolGroups.map(\.toolCount).max() ?? 0,
            agentInvocationCount: agentCount,
            vendorDistribution: vendorDist
        )
    }

    /// Build badge data from observability
    static func badgeData(from obs: SessionObservability) -> SessionBadgeData {
        SessionBadgeData(
            hasErrors: !obs.errorClassifications.isEmpty,
            errorTypes: obs.errorClassifications
        )
    }

    /// Build agent tree from OTEL invoke_agent spans
    static func buildAgentTree(
        sessionId: String,
        agentSpans: [OtelSpan],
        chatSpans: [OtelSpan]
    ) -> AgentTreeNode? {
        guard !agentSpans.isEmpty else { return nil }

        // Build span lookup by spanId
        var spanChildren: [String: [OtelSpan]] = [:]
        for span in agentSpans {
            if let parentId = span.parentSpanId {
                spanChildren[parentId, default: []].append(span)
            }
        }

        // Root-level agent spans (no parent in the agent span set)
        let agentIds = Set(agentSpans.map(\.spanId))
        let roots = agentSpans.filter { span in
            guard let parentId = span.parentSpanId else { return true }
            return !agentIds.contains(parentId)
        }

        func buildNode(_ span: OtelSpan) -> AgentTreeNode {
            let children = (spanChildren[span.spanId] ?? []).map { buildNode($0) }
            return AgentTreeNode(
                id: span.spanId,
                agentName: span.agentName ?? span.name,
                model: span.effectiveModel,
                totalInputTokens: span.inputTokens ?? 0,
                totalOutputTokens: span.outputTokens ?? 0,
                estimatedCost: estimateCostFromTokens(
                    model: span.effectiveModel,
                    inputTokens: span.inputTokens ?? 0,
                    outputTokens: span.outputTokens ?? 0,
                    cachedTokens: span.cachedTokens ?? 0
                ),
                toolCallCount: 0,
                durationMs: span.durationMs,
                children: children
            )
        }

        let rootChildren = roots.map { buildNode($0) }
        return AgentTreeNode(
            id: sessionId,
            agentName: "GitHub Copilot Chat",
            model: nil,
            totalInputTokens: rootChildren.reduce(0) { $0 + $1.totalInputTokens },
            totalOutputTokens: rootChildren.reduce(0) { $0 + $1.totalOutputTokens },
            estimatedCost: rootChildren.reduce(0) { $0 + $1.estimatedCost },
            toolCallCount: 0,
            durationMs: rootChildren.reduce(0) { $0 + $1.durationMs },
            children: rootChildren
        )
    }
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let mid = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
    return sorted[mid]
}
