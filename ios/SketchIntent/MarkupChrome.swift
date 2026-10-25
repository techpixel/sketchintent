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
    /// The record button beside Send, and the gap between them. Figma 56:1122.
    static let recordWidth: CGFloat = 44
    static let sendGap: CGFloat = 8
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
    static let liveRed = Color("LiveRed")
    static let liveRedDim = Color("LiveRedDim")
}

/// What the middle of the screen shows: the dotted canvas, or one Mac desktop.
enum CanvasSurface: Hashable {
    case canvas
    /// Zero-based position in Mission Control.
    case desktop(Int)
}

/// Sidebar toggle, working folder, desktop picker, send, live, and settings. Figma 51:823,
/// with the record button from 56:1087 and the live state from 56:1125.
struct TopBar: View {
    @Binding var showsSidebar: Bool
    var workingFolder: String
    var isChoosingFolder: Bool
    var isConnected: Bool
    var surface: CanvasSurface
    var desktopCount: Int
    var canSend: Bool
    var isSending: Bool
    var isLive: Bool
    var onChooseFolder: () -> Void
    var onClearFolder: () -> Void
    var onSurface: (CanvasSurface) -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onLive: () -> Void
    var onSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 16) {
                sidebarToggle
                HStack(spacing: 8) {
                    folderMenu
                    surfaceMenu
                }
                Spacer(minLength: ChromeMetrics.sendWidth + ChromeMetrics.sendGap + ChromeMetrics.recordWidth + 32)
                Button(action: onSettings) {
                    Image(systemName: "gear")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Settings")
            }
            if isLive {
                liveButton
            } else {
                HStack(spacing: ChromeMetrics.sendGap) {
                    sendButton
                    recordButton
                }
            }
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

    /// Red record button. Starts live mode, where the agent hears and sees the page without Send.
    private var recordButton: some View {
        Button(action: onLive) {
            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(.black)
                .padding(8)
                .background(Color.liveRed, in: RoundedRectangle(cornerRadius: ChromeMetrics.toolCornerRadius, style: .continuous))
        }
        .accessibilityLabel("Go live")
        .accessibilityHint("The agent listens and watches the page, and answers when you pause")
    }

    /// Dark red while live. Tapping it ends live mode.
    private var liveButton: some View {
        Button(action: onLive) {
            Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.liveRed)
                .symbolEffect(.pulse, options: .repeating)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(width: ChromeMetrics.sendWidth)
                .background(
                    Color.liveRedDim,
                    in: RoundedRectangle(cornerRadius: ChromeMetrics.buttonCornerRadius, style: .continuous)
                )
        }
        .accessibilityLabel("End live mode")
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

/// Tools on the left, ink colors on the right. Figma 48:732, selected tool from 66:1273.
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
                .foregroundStyle(selected ? .black : .white)
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
    var isLive: Bool
    /// What the dictation button, or live mode, has heard so far. Nil while nobody is talking.
    var heard: String?
    var onStop: () -> Void

    private static let listeningID = "listening"

    /// How many lines sit below the turn at `index`, so each line knows how far back it is.
    private func newerLines(than index: Int) -> Int {
        turns[(index + 1)...].reduce(heard == nil ? 0 : 1) { $0 + AgentTurnView.lineCount(of: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: isLive ? 20 : 28) {
                            if turns.isEmpty && heard == nil {
                                Text(isLive
                                    ? "Live. Talk and sketch. The agent picks it up each time you pause."
                                    : "Sketch on the screen, then send it to the agent. Or hold the dictation button and talk to it.")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                AgentTurnView(turn: turn, newerLines: newerLines(than: index))
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

/// The prompt is white. Tool calls are yellow with the tool name in bold, and canvas renders
/// are blue. Replies are yellow, read as Markdown. While the agent works, "Reading the
/// canvas..." (blue, Figma 55:1033) shows until it first acts, then "Thinking...". Figma 53:929.
/// A live turn puts the time before each line. Figma 56:1215.
/// Across the whole log, the newest line is full, the one before it 80%, and older lines 60%.
private struct AgentTurnView: View {
    var turn: AgentTurn
    /// Lines in later turns, and the listening row.
    var newerLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: turn.live ? 20 : 14) {
            if Self.showsPrompt(turn) {
                line(0, at: turn.startedAt) {
                    Text(turn.prompt.isEmpty ? "Sketched" : turn.prompt)
                        .foregroundStyle(.white)
                }
            }
            ForEach(Array(turn.steps.enumerated()), id: \.offset) { index, entry in
                line(stepsStart + index, at: entry.at, tint: Color.agentYellow) {
                    stepView(entry.step)
                }
            }
            switch turn.state {
            case .working:
                line(lineCount - 1, at: turn.steps.last?.at ?? turn.startedAt, tint: Color.agentYellow) {
                    ThinkingRow(reading: turn.steps.isEmpty)
                }
            case .stopped:
                Text("Stopped")
                    .foregroundStyle(.white)
                    .opacity(opacity(lineCount - 1))
                    .padding(.leading, turn.live ? Self.timeWidth + 10 : 0)
            case .finished:
                EmptyView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func showsPrompt(_ turn: AgentTurn) -> Bool {
        !turn.prompt.isEmpty || turn.live
    }

    /// The prompt, each step, and the working or stopped row.
    static func lineCount(of turn: AgentTurn) -> Int {
        (showsPrompt(turn) ? 1 : 0) + turn.steps.count + (turn.state == .finished ? 0 : 1)
    }

    private var lineCount: Int { Self.lineCount(of: turn) }
    private var stepsStart: Int { Self.showsPrompt(turn) ? 1 : 0 }

    private func opacity(_ position: Int) -> Double {
        switch newerLines + lineCount - 1 - position {
        case 0: 1
        case 1: 0.8
        default: 0.6
        }
    }

    private static let timeWidth: CGFloat = 33
    private static let timeFormat = Date.FormatStyle()
        .hour(.defaultDigits(amPM: .omitted))
        .minute(.twoDigits)

    /// The line alone, or for a live turn, the time it happened and then the line.
    @ViewBuilder
    private func line<Content: View>(
        _ position: Int,
        at date: Date,
        tint: Color = .white,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if turn.live {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(date, format: Self.timeFormat)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(minWidth: Self.timeWidth, alignment: .leading)
                    content()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content()
            }
        }
        .opacity(opacity(position))
    }

    @ViewBuilder
    private func stepView(_ step: AgentStep) -> some View {
        switch step {
        case .status(let lead, let name, let onCanvas):
            statusText(lead: lead, name: name)
                .foregroundStyle(onCanvas ? Color.agentBlue : Color.agentYellow)
        case .text(let text):
            MarkdownText(source: text)
                .foregroundStyle(Color.agentYellow)
        case .error(let message):
            Text(message)
                .foregroundStyle(.white)
        }
    }

    private func statusText(lead: String, name: String?) -> Text {
        guard let name, !name.isEmpty else { return Text(lead) }
        return Text(lead) + Text(name).bold() + Text("...")
    }
}

/// The words heard while the dictation button is held, in the prompt's white. Always the newest line.
private struct ListeningRow: View {
    var heard: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.agentYellow)
                .accessibilityHidden(true)
            Text(heard.isEmpty ? "Listening..." : heard)
                .foregroundStyle(.white)
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
    var body: some View {
        HStack(spacing: 10) {
            Text(reading ? "Reading the canvas..." : "Thinking...")
                .foregroundStyle(reading ? Color.agentBlue : Color.agentYellow)
            DitherMark(reading: reading)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}

/// The logo: a black hand-drawn asterisk ordered-dithered onto a yellow square. Figma 65:1258.
/// While the agent works it turns and its arms breathe, the dither crawls, and now and then the
/// rows tear sideways like the VGA displace export (Figma 65:1260). While reading the canvas the
/// square is blue and a scan line sweeps down it, inking the mark solid as it passes.
struct DitherMark: View {
    var reading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cells per side, and the frame rate of the dither, kept low so it reads as pixels.
    private static let cells = 16
    private static let fps = 12.0
    /// Angle (turns), length (of the half side) and half width (cells) of each arm. Uneven on
    /// purpose, like the pen-drawn mark.
    private static let arms: [(angle: Double, length: Double, width: Double)] = [
        (0.00, 0.92, 0.95), (0.10, 0.80, 0.80), (0.22, 0.95, 1.00),
        (0.33, 0.78, 0.85), (0.44, 0.90, 0.90), (0.56, 0.84, 0.80),
        (0.66, 0.96, 1.00), (0.78, 0.82, 0.85), (0.89, 0.90, 0.90),
    ]
    private static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        .map { ($0 + 0.5) / 16 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / Self.fps)) { timeline in
            let frame = reduceMotion ? 0 : Int(timeline.date.timeIntervalSinceReferenceDate * Self.fps)
            Canvas { context, size in
                draw(frame: frame, in: &context, size: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }

    private func draw(frame: Int, in context: inout GraphicsContext, size: CGSize) {
        let n = Self.cells
        let cell = min(size.width, size.height) / CGFloat(n)
        let t = Double(frame) / Self.fps
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(reading ? .agentBlue : .agentYellow))

        let spin = t * 0.08
        // Dither threshold shift: the pattern steps diagonally, a few cells a second.
        let shift = frame / 3
        // A torn band of rows for two frames out of every ~20, seeded by the frame.
        let tearSeed = Self.hash(frame / 20)
        let tearing = !reading && frame % 20 < 2 && tearSeed % 3 != 0
        let tearTop = tearSeed % (n - 4)
        let tearRows = tearTop..<(tearTop + 2 + tearSeed % 4)
        let tearBy = (tearSeed / 7) % 2 == 0 ? 2 : -3
        // While reading, the scan line's row; rows above it have been read.
        let scanRow = Int((t * 9).truncatingRemainder(dividingBy: Double(n + 6))) - 3

        var ink = Path()
        for row in 0..<n {
            let shifted = tearing && tearRows.contains(row) ? tearBy : 0
            for col in 0..<n {
                let x = (Double(col - shifted) + 0.5) / Double(n) * 2 - 1
                let y = (Double(row) + 0.5) / Double(n) * 2 - 1
                var level = Self.coverage(x: x, y: y, spin: spin, t: t, cell: 2 / Double(n))
                if reading {
                    level = row < scanRow ? min(1, level * 1.6) : level * 0.55
                    if row == scanRow { level = max(level, 0.5) }
                }
                let threshold = Self.bayer[((row + shift) & 3) * 4 + ((col + shift) & 3)]
                if level > threshold {
                    ink.addRect(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
        }
        context.fill(ink, with: .color(.black))
    }

    /// How much ink covers a point in the -1...1 square: 1 on an arm's spine, fading over a
    /// couple of cells so the dither has a soft edge to chew on.
    private static func coverage(x: Double, y: Double, spin: Double, t: Double, cell: Double) -> Double {
        var best = 0.0
        for (index, arm) in arms.enumerated() {
            let breath = 1 + 0.12 * sin(t * 2.4 + Double(index) * 1.7)
            let angle = (arm.angle + spin) * 2 * .pi
            let tipX = cos(angle) * arm.length * breath
            let tipY = sin(angle) * arm.length * breath
            // Distance from the point to the segment from the centre to the tip.
            let along = max(0, min(1, (x * tipX + y * tipY) / (tipX * tipX + tipY * tipY)))
            let distance = hypot(x - tipX * along, y - tipY * along)
            // Arms taper toward the tip.
            let halfWidth = arm.width * cell * (1.15 - 0.45 * along)
            best = max(best, smoothstep(halfWidth + cell * 1.4, halfWidth - cell * 0.6, distance))
        }
        let core = smoothstep(cell * 3.4, cell * 1.6, hypot(x, y))
        return max(best, core)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let k = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return k * k * (3 - 2 * k)
    }

    private static func hash(_ value: Int) -> Int {
        var h = UInt32(truncatingIfNeeded: value) &* 2_654_435_761
        h ^= h >> 15
        return Int(h % 997)
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
