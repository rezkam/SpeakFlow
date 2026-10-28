import AppKit
import ApplicationServices

/// The operating-system boundary for capturing one focused input target.
@MainActor
struct TargetCaptureAccessibility {
    var frontmostPid: () -> pid_t?
    var prepareApplication: (pid_t) -> AXError
    var systemFocus: () -> (AXError, AXUIElement?)
    var processId: (AXUIElement) -> pid_t?
    var window: (AXUIElement) -> AXUIElement?
    var sameApplication: (pid_t, pid_t) -> Bool

    static var live: Self {
        Self(
            frontmostPid: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            prepareApplication: { prepareApplication($0) },
            systemFocus: { focusedElement(of: AXUIElementCreateSystemWide()) },
            processId: {
                var pid: pid_t = 0
                return AXUIElementGetPid($0, &pid) == .success && pid > 0 ? pid : nil
            },
            window: { elementAttribute(kAXWindowAttribute as CFString, of: $0).1 },
            sameApplication: {
                $0 == $1 || ApplicationOwnership.matches(
                    target: ApplicationOwnership.applicationURL(for: $0),
                    candidate: ApplicationOwnership.applicationURL(for: $1)
                )
            }
        )
    }

    nonisolated static func prepareApplication(
        _ pid: pid_t,
        setAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue
    ) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Electron documents this request, even when the attribute cannot be read back.
        _ = setAttribute(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let name = "AXEnhancedUserInterface" as CFString
        var enabled: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, name, &enabled) == .success,
           (enabled as? NSNumber)?.boolValue == true { return .success }
        var settable = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(app, name, &settable)
        guard status == .success else { return status }
        guard settable.boolValue else { return .attributeUnsupported }
        // Some Electron versions enable the tree but return notImplemented.
        // Only a subsequent focused-element query can establish a valid target.
        return setAttribute(app, name, kCFBooleanTrue)
    }

    private static func focusedElement(of element: AXUIElement) -> (AXError, AXUIElement?) {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return elementAttribute(kAXFocusedUIElementAttribute as CFString, of: element)
    }

    private static func elementAttribute(_ name: CFString, of element: AXUIElement) -> (AXError, AXUIElement?) {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (status, nil)
        }
        // The type identity was checked above.
        // swiftlint:disable:next force_cast
        return (status, (value as! AXUIElement))
    }
}
