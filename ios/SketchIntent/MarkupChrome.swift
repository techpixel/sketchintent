import SwiftUI
import UIKit

/// Spacing from the "ui v2" frames, Figma 48:695, 53:884, 55:947, and 55:981.
enum ChromeMetrics {
    static let topBarHeight: CGFloat = 69
    static let bottomBarHeight: CGFloat = 68
    static let sidebarWidth: CGFloat = 320
    static let edgeInset: CGFloat = 16
    static let pillHeight: CGFloat = 33
    static let pillCornerRadius: CGFloat = 8
    static let buttonCornerRadius: CGFloat = 16
    static let sendWidth: CGFloat = 200
    static let toolWidth: CGFloat = 50
    static let toolCornerRadius: CGFloat = 8
    static let toolGap: CGFloat = 8
    /// The color swatches sit 20pt from the right edge.
    static let swatchTrailing: CGFloat = 20
    static let swatchSide: CGFloat = 38
    static let swatchDot: CGFloat = 28
    static let swatchGap: CGFloat = 9
    static let canvasCornerRadius: CGFloat = 16
    static let dotSpacing: CGFloat = 24
    static let dotDiameter: CGFloat = 4
    static let dotInset: CGFloat = 9
}

private extension Color {
    static let agentYellow = Color("AgentYellow")
    static let agentBlue = Color("AgentBlue")
    static let chromePill = Color("ChromePill")
    static let chromeButton = Color("ChromeButton")
    static let toolSelected = Color("ToolSelected")
    static let canvasLine = Color("CanvasLine")
}

/// What the middle of the screen shows: the dotted canvas, or one Mac desktop.
enum CanvasSurface: Hashable {
    case canvas
    /// Zero-based position in Mission Control.
    case desktop(Int)
}

/// Sidebar toggle, working folder, desktop picker, send, and settings. Figma 51:823.
struct TopBar: View {
    @Binding var showsSidebar: Bool
    var workingFolder: String
    var isChoosingFolder: Bool
    var isConnected: Bool
    var surface: CanvasSurface
    var desktopCount: Int
    var canSend: Bool
    var isSending: Bool
    var onChooseFolder: () -> Void
    var onClearFolder: () -> Void
    var onSurface: (CanvasSurface) -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                sidebarToggle
                HStack(spacing: 8) {
                    folderMenu
                    surfaceMenu
                }
                Spacer(minLength: ChromeMetrics.sendWidth + 32)
                Button(action: onSettings) {
                    Image(systemName: "gear")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Settings")
            }
            sendButton
        }
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .frame(height: ChromeMetrics.topBarHeight)
    }

    private var sidebarToggle: some View {
        Button {
            showsSidebar.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.title2)
                .foregroundStyle(showsSidebar ? Color.black : Color.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .background(
                    showsSidebar ? Color.white : Color.clear,
                    in: RoundedRectangle(cornerRadius: ChromeMetrics.toolCornerRadius, style: .continuous)
                )
        }
        .accessibilityLabel("Agent")
        .accessibilityAddTraits(showsSidebar ? .isSelected : [])
    }

    private var folderMenu: some View {
        Menu {
            Button("Choose Folder on Mac…", systemImage: "folder") {
                onChooseFolder()
            }
            .disabled(!isConnected || isChoosingFolder)
            if !workingFolder.isEmpty {
                Button("Clear Folder", systemImage: "xmark", role: .destructive) {
                    onClearFolder()
                }
            }
        } label: {
            ChromePill {
                HStack(spacing: 4) {
                    if isChoosingFolder {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "folder")
                    }
                    Text(folderName)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel("Working folder")
        .accessibilityValue(workingFolder.isEmpty ? "Not chosen" : workingFolder)
    }

    private var folderName: String {
        guard !workingFolder.isEmpty else { return "No folder" }
        let name = (workingFolder as NSString).lastPathComponent
        return name.isEmpty ? workingFolder : name
    }

    private var surfaceMenu: some View {
        Menu {
            Picker("Show", selection: Binding(get: { surface }, set: onSurface)) {
                Text("Canvas").tag(CanvasSurface.canvas)
                ForEach(0..<desktopCount, id: \.self) { index in
                    Text("Space \(index + 1)").tag(CanvasSurface.desktop(index))
                }
            }
            .pickerStyle(.inline)
        } label: {
            ChromePill {
                Text(surfaceName)
                    .lineLimit(1)
            }
        }
        .accessibilityLabel("Canvas or desktop")
        .accessibilityValue(surfaceName)
    }

    private var surfaceName: String {
        switch surface {
        case .canvas:
            return "Canvas"
        case .desktop(let index):
            return index >= 0 ? "Space \(index + 1)" : "Space"
        }
    }

    /// Yellow arrow while there is a sketch to send. Pause stops the agent while it works.
    private var sendButton: some View {
        Button(action: isSending ? onStop : onSend) {
            Image(systemName: isSending ? "pause.fill" : "arrow.up")
                .font(.title2.weight(.medium))
                .foregroundStyle(isSending ? Color.white : Color.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(width: ChromeMetrics.sendWidth)
                .background(
                    isSending ? Color.chromeButton : Color.agentYellow,
                    in: RoundedRectangle(cornerRadius: ChromeMetrics.buttonCornerRadius, style: .continuous)
                )
        }
        .disabled(!isSending && !canSend)
        .opacity(isSending || canSend ? 1 : 0.4)
        .accessibilityLabel(isSending ? "Stop agent" : "Send to AI")
    }
}

/// Grey pill with a trailing chevron. Figma 53:907.
private struct ChromePill<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            content
            Image(systemName: "chevron.down")
                .font(.footnote.weight(.semibold))
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: ChromeMetrics.pillHeight)
        .background(Color.chromePill, in: RoundedRectangle(cornerRadius: ChromeMetrics.pillCornerRadius, style: .continuous))
    }
}

/// Tools on the left, ink colors on the right. Figma 48:732.
/// Holding the dictation button talks to the agent until the finger lifts.
struct BottomBar: View {
    var tool: SketchTool
    var inkColor: InkColor
    var canClear: Bool
    var onTool: (SketchTool) -> Void
    var onColor: (InkColor) -> Void
    var onClear: () -> Void
    var onDictationBegan: () -> Void = {}
    var onDictationEnded: () -> Void = {}
    @Namespace private var toolHighlight
    @State private var pressingDictation = false
    @State private var heldDictation = false
    @State private var dictationHoldItem: DispatchWorkItem?

    private static let dictationHoldDelay = 0.35

    var body: some View {
        HStack(spacing: ChromeMetrics.toolGap) {
            tools
            if canClear {
                Button(action: onClear) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(.vertical, 8)
                        .frame(width: ChromeMetrics.toolWidth)
                }
                .accessibilityLabel("Clear sketch")
            }
            Spacer(minLength: 16)
            HStack(spacing: ChromeMetrics.swatchGap) {
                ForEach(InkColor.allCases, id: \.self) { candidate in
                    swatch(candidate)
                }
            }
            .padding(.trailing, ChromeMetrics.swatchTrailing - ChromeMetrics.edgeInset)
        }
        .padding(.horizontal, ChromeMetrics.edgeInset)
        .frame(height: ChromeMetrics.bottomBarHeight)
    }

    /// A tap picks a tool. A swipe along the row picks whichever tool is under the finger,
    /// and the highlight slides with it.
    private var tools: some View {
        HStack(spacing: ChromeMetrics.toolGap) {
            ForEach(SketchTool.edgeOrder, id: \.self) { candidate in
                toolButton(candidate)
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { drag in
                    // Talking to the agent keeps the tool where it is.
                    guard !(pressingDictation && heldDictation) else { return }
                    let order = SketchTool.edgeOrder
                    let slot = ChromeMetrics.toolWidth + ChromeMetrics.toolGap
                    let index = Int((drag.location.x / slot).rounded(.down))
                    let candidate = order[min(max(index, 0), order.count - 1)]
                    if candidate != tool {
                        onTool(candidate)
                    }
                }
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: tool)
    }

    private func toolButton(_ candidate: SketchTool) -> some View {
        let selected = candidate == tool
        return Button {
            // A hold on dictation talked to the agent, so letting go does not pick the tool.
            guard !(candidate == .voice && heldDictation) else { return }
            onTool(candidate)
        } label: {
            Image(systemName: candidate.symbolName)
                .font(.title2)
                .foregroundStyle(.white)
                .padding(.vertical, 8)
                .frame(width: ChromeMetrics.toolWidth)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: ChromeMetrics.toolCornerRadius, style: .continuous)
                            .fill(Color.toolSelected)
                            .matchedGeometryEffect(id: "tool", in: toolHighlight)
                    }
                }
        }
        .simultaneousGesture(dictationHold, including: candidate == .voice ? .all : .subviews)
        .accessibilityLabel(candidate.accessibilityName)
        .accessibilityHint(candidate == .voice ? "Hold to talk to the agent" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A still hold on the dictation button starts listening, and lifting the finger ends it.
    /// A tap still picks the tool, and a finger that moves before the hold is a swipe along the row.
    private var dictationHold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if !pressingDictation {
                    pressingDictation = true
                    heldDictation = false
                    let item = DispatchWorkItem {
                        heldDictation = true
                        onDictationBegan()
                    }
                    dictationHoldItem = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.dictationHoldDelay, execute: item)
                } else if !heldDictation, hypot(drag.translation.width, drag.translation.height) > 10 {
                    dictationHoldItem?.cancel()
                    dictationHoldItem = nil
                }
            }
            .onEnded { _ in
                pressingDictation = false
                dictationHoldItem?.cancel()
                dictationHoldItem = nil
                if heldDictation {
                    onDictationEnded()
                }
            }
    }

    /// A 28pt dot. The chosen color also gets a 2pt ring. Black has a grey rim
    /// so it shows on the black bar, and its ring is grey for the same reason.
    private func swatch(_ candidate: InkColor) -> some View {
        let selected = candidate == inkColor
        let fill = Color(uiColor: candidate.color)
        let ring = candidate == .black ? Color.canvasLine : fill
        return Button {
            onColor(candidate)
        } label: {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: ChromeMetrics.swatchDot, height: ChromeMetrics.swatchDot)
                if candidate == .black {
                    Circle()
                        .strokeBorder(Color.canvasLine, lineWidth: 1)
                        .frame(width: ChromeMetrics.swatchDot, height: ChromeMetrics.swatchDot)
                }
                if selected {
                    Circle()
                        .strokeBorder(ring, lineWidth: 2)
                        .frame(width: ChromeMetrics.swatchSide, height: ChromeMetrics.swatchSide)
                }
            }
            .frame(width: ChromeMetrics.swatchSide, height: ChromeMetrics.swatchSide)
        }
        .accessibilityLabel("\(candidate.accessibilityName) ink")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The agent's side of each sketch. Figma 53:918.
struct AgentSidebar: View {
    var turns: [AgentTurn]
    var isSending: Bool
    /// What the dictation button has heard so far, or nil when it is not held.
    var heard: String?
    var onStop: () -> Void

    private static let listeningID = "listening"

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if turns.isEmpty && heard == nil {
                                Text("Sketch on the screen, then send it to the agent. Or hold the dictation button and talk to it.")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            ForEach(turns) { turn in
                                AgentTurnView(turn: turn)
                                    .id(turn.id)
                            }
                            if let heard {
                                ListeningRow(heard: heard)
                                    .id(Self.listeningID)
                            }
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ChromeMetrics.edgeInset)
                        .padding(.vertical, ChromeMetrics.edgeInset)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                    }
                    .onChange(of: turns) { _, latest in
                        guard let last = latest.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onChange(of: heard) { _, heard in
                        guard heard != nil else { return }
                        reader.scrollTo(Self.listeningID, anchor: .bottom)
                    }
                }
            }
            if isSending {
                Button(action: onStop) {
                    Text("Stop agent")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            Color.chromeButton,
                            in: RoundedRectangle(cornerRadius: ChromeMetrics.buttonCornerRadius, style: .continuous)
                        )
                }
                .padding([.horizontal, .bottom], ChromeMetrics.edgeInset)
            }
        }
        .frame(width: ChromeMetrics.sidebarWidth)
    }
}

/// The prompt is half white. Tool calls are half yellow with the tool name in bold, and
/// canvas renders are blue. Replies are yellow at 80%, read as Markdown. While the agent works, "Reading the
/// canvas..." (blue, Figma 55:1033) shows until it first acts, then "Thinking...". Figma 53:929.
private struct AgentTurnView: View {
    var turn: AgentTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !turn.prompt.isEmpty {
                Text(turn.prompt)
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(turn.steps.enumerated()), id: \.offset) { _, step in
                stepView(step)
            }
            switch turn.state {
            case .working:
                ThinkingRow(reading: turn.steps.isEmpty)
            case .stopped:
                Text("Stopped")
                    .foregroundStyle(.white.opacity(0.5))
            case .finished:
                EmptyView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stepView(_ step: AgentStep) -> some View {
        switch step {
        case .status(let lead, let name, let onCanvas):
            statusText(lead: lead, name: name)
                .foregroundStyle(onCanvas ? Color.agentBlue : Color.agentYellow)
                .opacity(onCanvas ? 0.8 : 0.5)
        case .text(let text):
            MarkdownText(source: text)
                .foregroundStyle(Color.agentYellow)
                .opacity(0.8)
        case .error(let message):
            Text(message)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func statusText(lead: String, name: String?) -> Text {
        guard let name, !name.isEmpty else { return Text(lead) }
        return Text(lead) + Text(name).bold() + Text("...")
    }
}

/// The words heard while the dictation button is held, in the prompt's half white.
private struct ListeningRow: View {
    var heard: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.agentYellow)
                .accessibilityHidden(true)
            Text(heard.isEmpty ? "Listening..." : heard)
                .foregroundStyle(.white.opacity(heard.isEmpty ? 0.5 : 0.8))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One block of a Markdown reply. Inline marks stay in the text and SwiftUI draws them.
enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// `marker` is a bullet, or the number of an ordered item. `depth` counts nesting.
    case item(marker: String, text: String, depth: Int)
    case quote(String)
    case code(String)
    case rule

    /// Reads the reply line by line. A reply still streaming in may stop mid-block, so an
    /// open code fence runs to the end.
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
            if !quote.isEmpty {
                blocks.append(.quote(quote.joined(separator: "\n")))
                quote = []
            }
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flush()
                blocks.append(.rule)
            } else if let item = item(line) {
                flush()
                blocks.append(item)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else {
                if !quote.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        flush()
        if let code {
            blocks.append(.code(code.joined(separator: "\n").trimmingCharacters(in: .newlines)))
        }
        return blocks
    }

    /// Bold, italics, code, and links, keeping the line breaks.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func item(_ line: String) -> MarkdownBlock? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(indent.count)
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .item(marker: "•", text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
        }
        let digits = rest.prefix { $0.isNumber }
        let after = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3, let dot = after.first, dot == "." || dot == ")",
           after.dropFirst().first == " " {
            return .item(marker: "\(digits).", text: after.dropFirst(2).trimmingCharacters(in: .whitespaces), depth: depth)
        }
        return nil
    }
}

/// The agent's reply as Markdown. Headings are bold, lists hang their bullets, quotes get a
/// rule on the left, and code blocks are monospaced on a faint panel that scrolls sideways.
private struct MarkdownText: View {
    var source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .tint(Color.agentYellow)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(MarkdownBlock.inline(text))
        case .heading(let level, let text):
            Text(MarkdownBlock.inline(text))
                .font(level <= 2 ? .headline : .callout.weight(.semibold))
                .padding(.top, 4)
        case .item(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .monospacedDigit()
                Text(MarkdownBlock.inline(text))
            }
            .padding(.leading, CGFloat(depth) * 14)
        case .quote(let text):
            Text(MarkdownBlock.inline(text))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .frame(width: 2)
                        .opacity(0.5)
                }
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Rectangle()
                .frame(height: 1)
                .opacity(0.3)
        }
    }
}

private struct ThinkingRow: View {
    /// The agent is still looking at the sketch, before its first step.
    var reading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wobble = false

    var body: some View {
        HStack(spacing: reading ? 6 : 10) {
            Text(reading ? "Reading the canvas..." : "Thinking...")
                .foregroundStyle(reading ? Color.agentBlue : Color.agentYellow)
            Image(reading ? "ReadingBlob" : "ThinkingBlob")
                .resizable()
                .aspectRatio(34 / 45, contentMode: .fit)
                .frame(height: 19)
                .rotationEffect(.degrees(wobble ? 12 : -12))
                .accessibilityHidden(true)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                wobble = true
            }
        }
    }
}

/// The black drawing page: a 1pt rim and a 24pt dot grid. Figma 55:948.
struct DotCanvas: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: ChromeMetrics.canvasCornerRadius, style: .continuous)
        Canvas { context, size in
            let dot = ChromeMetrics.dotDiameter
            var y = ChromeMetrics.dotInset
            while y + dot <= size.height {
                var x = ChromeMetrics.dotInset
                while x + dot <= size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)), with: .color(.canvasLine))
                    x += ChromeMetrics.dotSpacing
                }
                y += ChromeMetrics.dotSpacing
            }
        }
        .background(Color.black)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.canvasLine, lineWidth: 1))
        .accessibilityHidden(true)
    }
}
