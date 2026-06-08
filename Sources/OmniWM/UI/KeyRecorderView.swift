import AppKit
import Carbon
import SwiftUI

struct KeyRecorderView: NSViewRepresentable {
    let accessibilityLabel: String
    var allowsBareKeys: Bool = false
    var hyperTrigger: HyperKeyTrigger = .default
    let onCapture: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.recordingAccessibilityLabel = accessibilityLabel
        view.allowsBareKeys = allowsBareKeys
        view.hyperTrigger = hyperTrigger
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.updateAccessibility()
        return view
    }

    func updateNSView(_ nsView: KeyRecorderNSView, context _: Context) {
        nsView.recordingAccessibilityLabel = accessibilityLabel
        nsView.allowsBareKeys = allowsBareKeys
        nsView.hyperTrigger = hyperTrigger
        nsView.updateAccessibility()
    }
}

struct HyperTriggerRecorderView: NSViewRepresentable {
    let accessibilityLabel: String
    let onCapture: (HyperKeyTrigger) -> Void
    let onCancel: () -> Void

    func makeNSView(context _: Context) -> HyperTriggerRecorderNSView {
        let view = HyperTriggerRecorderNSView()
        view.recordingAccessibilityLabel = accessibilityLabel
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.updateAccessibility()
        return view
    }

    func updateNSView(_ nsView: HyperTriggerRecorderNSView, context _: Context) {
        nsView.recordingAccessibilityLabel = accessibilityLabel
        nsView.updateAccessibility()
    }
}

class HyperTriggerRecorderNSView: NSView {
    var onCapture: ((HyperKeyTrigger) -> Void)?
    var onCancel: (() -> Void)?
    var recordingAccessibilityLabel = "Recording Hyper key"

    private let label = NSTextField(labelWithString: "Press key or mouse button...")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 4
        focusRingType = .exterior

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        addSubview(label)

        updateAccessibility()

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(recordingAccessibilityLabel)
        setAccessibilityValue("Recording. Press a key or extra mouse button.")
        setAccessibilityHelp("Press a key or extra mouse button. Press Escape to cancel recording.")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                _ = self.window?.makeFirstResponder(self)
                NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            }
        }
    }

    private func capture(_ trigger: HyperKeyTrigger) {
        onCapture?(trigger)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }
        capture(.key(UInt32(event.keyCode)))
    }

    override func flagsChanged(with event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let modifier = HyperKeyTrigger.modifierMask(for: keyCode)
        if modifier != 0 {
            capture(.modifier(modifier))
        } else {
            capture(.key(keyCode))
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        capture(.mouseButton(Int64(event.buttonNumber)))
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}

class KeyRecorderNSView: NSView {
    var onCapture: ((KeyBinding) -> Void)?
    var onCancel: (() -> Void)?
    var recordingAccessibilityLabel = "Recording hotkey"
    var allowsBareKeys = false
    var hyperTrigger: HyperKeyTrigger = .default {
        didSet { isVirtualHyperActive = false }
    }

    private let label = NSTextField(labelWithString: "Press keys...")
    private var isVirtualHyperActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.cornerRadius = 4
        focusRingType = .exterior

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        addSubview(label)

        updateAccessibility()

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func updateAccessibility() {
        setAccessibilityRole(.group)
        setAccessibilityLabel(recordingAccessibilityLabel)
        setAccessibilityValue("Recording. Press a key combination.")
        setAccessibilityHelp("Press a key combination. Press Escape to cancel recording.")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startRecording()
        } else {
            stopRecording()
        }
    }

    private func startRecording() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            if window.makeFirstResponder(self) {
                NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
            }
        }
    }

    private func stopRecording() {}

    @discardableResult
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            onCancel?()
            return true
        }

        if handleVirtualHyperTriggerEvent(event) {
            return true
        }
        guard event.type != .keyUp else { return false }

        guard let binding = binding(from: event) else { return false }

        stopRecording()
        onCapture?(binding)
        return true
    }

    private func binding(from event: NSEvent) -> KeyBinding? {
        guard event.type != .flagsChanged else { return nil }

        let carbonModifiers = carbonModifiersFromNSEvent(event)
        let usesSemanticHyper = isVirtualHyperActive || carbonModifiers == KeySymbolMapper.hyperModifiers
        let normalizedModifiers = usesSemanticHyper ? semanticHyperModifiers(from: carbonModifiers) : carbonModifiers
        let requiresModifier = !isSpecialKey(Int(event.keyCode))
        guard allowsBareKeys || usesSemanticHyper || !requiresModifier || normalizedModifiers != 0 else { return nil }

        if usesSemanticHyper {
            return KeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: normalizedModifiers,
                usesHyper: true
            )
        }

        return KeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: normalizedModifiers
        )
    }

    private func semanticHyperModifiers(from carbonModifiers: UInt32) -> UInt32 {
        if carbonModifiers == KeySymbolMapper.hyperModifiers {
            return 0
        }
        return carbonModifiers & ~hyperTrigger.modifierMaskToExclude
    }

    private func carbonModifiersFromNSEvent(_ event: NSEvent) -> UInt32 {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        return modifiers
    }

    private func isSpecialKey(_ keyCode: Int) -> Bool {
        (keyCode >= kVK_F1 && keyCode <= kVK_F12) ||
            keyCode == kVK_F13 || keyCode == kVK_F14 ||
            keyCode == kVK_F15 || keyCode == kVK_F16 ||
            keyCode == kVK_F17 || keyCode == kVK_F18 ||
            keyCode == kVK_F19 || keyCode == kVK_F20
    }

    private func handleVirtualHyperTriggerEvent(_ event: NSEvent) -> Bool {
        if handleVirtualHyperMouseEvent(event) {
            return true
        }
        let keyCode = UInt32(event.keyCode)
        guard hyperTrigger.matchesPhysicalKeyCode(keyCode) else { return false }

        switch event.type {
        case .flagsChanged:
            if let modifierActive = modifierFlagIsActive(for: keyCode, event: event) {
                isVirtualHyperActive = isVirtualHyperActive ? false : modifierActive
            } else if keyCode == UInt32(kVK_CapsLock) {
                isVirtualHyperActive = event.modifierFlags.contains(.capsLock)
            } else {
                isVirtualHyperActive = true
            }
            return true
        case .keyDown:
            isVirtualHyperActive = true
            return true
        case .keyUp:
            isVirtualHyperActive = false
            return true
        default:
            return false
        }
    }

    private func handleVirtualHyperMouseEvent(_ event: NSEvent) -> Bool {
        guard case let .mouseButton(button) = hyperTrigger,
              Int64(event.buttonNumber) == button
        else { return false }

        switch event.type {
        case .otherMouseDown:
            isVirtualHyperActive = true
            return true
        case .otherMouseUp:
            isVirtualHyperActive = false
            return true
        default:
            return false
        }
    }

    private func modifierFlagIsActive(for keyCode: UInt32, event: NSEvent) -> Bool? {
        switch Int(keyCode) {
        case kVK_Shift,
             kVK_RightShift:
            return event.modifierFlags.contains(.shift)
        case kVK_Control,
             kVK_RightControl:
            return event.modifierFlags.contains(.control)
        case kVK_Option,
             kVK_RightOption:
            return event.modifierFlags.contains(.option)
        case kVK_Command,
             kVK_RightCommand:
            return event.modifierFlags.contains(.command)
        default:
            return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        guard !handleKeyEvent(event) else { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = handleKeyEvent(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard !handleVirtualHyperMouseEvent(event) else { return }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard !handleVirtualHyperMouseEvent(event) else { return }
        super.otherMouseUp(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        return handleKeyEvent(event)
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}
