import SwiftUI

// MARK: - User Message

struct UserMessageBubble: View {
    let record: CopilotRecord

    private var displayText: String {
        record.data?.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        if !displayText.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                MarkdownContentView(content: displayText, fontSize: 13)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 600, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let record: CopilotRecord
    let toolResultMap: [String: ToolResultEntry]
    var searchText: String = ""

    private var textContent: String {
        record.data?.content ?? ""
    }

    private var reasoningText: String? {
        record.data?.reasoningText
    }

    private var toolRequests: [CopilotToolRequest] {
        record.data?.toolRequests ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with Copilot avatar
            HStack(spacing: 6) {
                CopilotAvatarView(size: 20)

                Spacer()
            }

            // Reasoning block (if present)
            if let reasoning = reasoningText, !reasoning.isEmpty {
                ThinkingBlockView(text: reasoning, searchText: searchText)
            }

            // Text content
            if !textContent.isEmpty {
                CollapsibleTextView(content: textContent, fontSize: 13)
            }

            // Tool calls
            ForEach(Array(toolRequests.enumerated()), id: \.offset) { _, toolReq in
                let result = toolResultMap[toolReq.toolCallId ?? ""]
                ToolCallBlockView(
                    toolName: toolReq.name ?? "unknown",
                    input: toolReq.arguments?.dictionaryValue ?? [:],
                    resultContent: result?.content,
                    isError: result?.isError ?? false,
                    searchText: searchText
                )
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Copilot Avatar

struct CopilotAvatarView: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.6))
            .foregroundStyle(.purple)
            .frame(width: size, height: size)
            .background(Circle().fill(.purple.opacity(0.1)))
    }
}

// MARK: - Collapsible Text Block

struct CollapsibleTextView: View {
    let content: String
    let fontSize: CGFloat
    @State private var isCollapsed = true
    @State private var fullHeight: CGFloat = 0

    private let collapseHeight: CGFloat = 300

    var body: some View {
        if isLongContent {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownContentView(content: content, fontSize: fontSize)
                    .textSelection(.enabled)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { fullHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in fullHeight = h }
                        }
                    )
                    .frame(maxHeight: isCollapsed ? collapseHeight : nil, alignment: .top)
                    .clipped()

                if isCollapsed {
                    LinearGradient(
                        colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                    .offset(y: -40)
                    .allowsHitTesting(false)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(isCollapsed ? "Show more" : "Show less")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        } else {
            MarkdownContentView(content: content, fontSize: fontSize)
                .textSelection(.enabled)
        }
    }

    private var isLongContent: Bool {
        let lineCount = content.components(separatedBy: "\n").count
        return lineCount > 15 || content.count > 1500
    }
}
