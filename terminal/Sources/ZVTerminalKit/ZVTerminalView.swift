// Zeon Remote - terminal view for SSH / Telnet sessions.
//
// Wraps SwiftTerm's TerminalView (an xterm compatible emulator) behind a
// small Objective-C API; see ZVTerminalView.h on the app side.

import AppKit
import SwiftTerm

@objc(ZVTerminalView)
public final class ZVTerminalView: NSView, TerminalViewDelegate {
    private let term: TerminalView

    /// Bytes typed by the user, to be sent to the remote side
    @objc public var onSend: ((Data) -> Void)?
    /// New size in columns / rows
    @objc public var onResize: ((Int, Int) -> Void)?
    @objc public var onTitle: ((String) -> Void)?
    @objc public var onBell: (() -> Void)?

    @objc public override init(frame: NSRect) {
        // A little padding so text doesn't touch the window edges
        term = TerminalView(frame: NSRect(origin: .zero, size: frame.size).insetBy(dx: 6, dy: 4))
        super.init(frame: frame)
        wantsLayer = true
        term.terminalDelegate = self
        term.autoresizingMask = [.width, .height]
        term.optionAsMetaKey = false     // keep Option for typing characters (@, €, …)
        addSubview(term)
        applyTheme()
        fontSize = 13
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Output from the remote side

    @objc(feedData:)
    public func feed(_ data: Data) {
        let bytes = [UInt8](data)
        term.feed(byteArray: bytes[...])
    }

    @objc(feedText:)
    public func feedText(_ text: String) {
        term.feed(text: text)
    }

    // MARK: Appearance

    @objc public var fontSize: CGFloat = 13 {
        didSet {
            let size = max(8, min(fontSize, 36))
            term.font = NSFont(name: "SFMono-Regular", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    @objc public var optionAsMeta: Bool {
        get { term.optionAsMetaKey }
        set { term.optionAsMetaKey = newValue }
    }

    private func applyTheme() {
        term.nativeBackgroundColor = NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        term.nativeForegroundColor = NSColor(calibratedRed: 0.90, green: 0.91, blue: 0.93, alpha: 1)
        term.caretColor = NSColor.systemBlue
        layer?.backgroundColor = term.nativeBackgroundColor.cgColor
    }

    @objc public var columns: Int { term.getTerminal().cols }
    @objc public var rows: Int { term.getTerminal().rows }

    @objc public func focus() {
        window?.makeFirstResponder(term)
    }

    /// Clears the screen and scrollback locally
    @objc public func resetTerminal() {
        term.getTerminal().resetToInitialState()
        term.needsDisplay = true
    }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onSend?(Data(data))
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func bell(source: TerminalView) {
        if let onBell { onBell() } else { NSSound.beep() }
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}
