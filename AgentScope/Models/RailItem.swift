import Foundation

enum RailItem: String, CaseIterable, Hashable, Sendable {
    // Primary (above separator)
    case analytics
    case sessions
    case tools
    case agents
    case timeline

    // Config (below separator)
    case instructions
    case prompts
    case mcps
    case memory
    case configHealth

    // Pinned bottom
    case settings

    var icon: String {
        switch self {
        case .analytics:    return "chart.bar"
        case .sessions:     return "text.line.first.and.arrowtriangle.forward"
        case .tools:        return "wrench.and.screwdriver"
        case .agents:       return "person.2"
        case .timeline:     return "clock.arrow.circlepath"
        case .instructions: return "doc.text"
        case .prompts:      return "text.bubble"
        case .mcps:         return "point.3.connected.trianglepath.dotted"
        case .memory:       return "brain"
        case .configHealth: return "checkmark.shield"
        case .settings:     return "gear"
        }
    }

    var label: String {
        switch self {
        case .analytics:    return "Analytics"
        case .sessions:     return "Sessions"
        case .tools:        return "Tools"
        case .agents:       return "Agents"
        case .timeline:     return "Timeline"
        case .instructions: return "Instructions"
        case .prompts:      return "Prompts"
        case .mcps:         return "MCPs"
        case .memory:       return "Memory"
        case .configHealth: return "Health"
        case .settings:     return "Settings"
        }
    }

    static var primaryItems: [RailItem] { [.analytics, .sessions, .tools, .agents, .timeline] }
    static var configItems: [RailItem] { [.instructions, .prompts, .mcps, .memory, .configHealth] }
}
