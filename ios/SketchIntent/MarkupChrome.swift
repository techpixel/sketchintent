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
struct BottomBar: View {
    var tool: SketchTool
    var inkColor: InkColor
    var canClear: Bool
    var onTool: (SketchTool) -> Void
    var onColor: (InkColor) -> Void
    var onClear: () -> Void
    @Namespace private var toolHighlight

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
        .accessibilityLabel(candidate.accessibilityName)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
    var onStop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if turns.isEmpty {
                                Text("Sketch on the screen, then send it to the agent.")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            ForEach(turns) { turn in
                                AgentTurnView(turn: turn)
                                    .id(turn.id)
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
/// canvas renders are blue. Replies are yellow at 80%. While the agent works, "Reading the
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
            Text(text)
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
