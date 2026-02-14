#!/usr/bin/env swift
//
// simulate-double-tap-control.swift
//
// Simulates a double-tap of the Control key by posting flagsChanged CGEvents.
// Targets any CGEvent.tapCreate listener monitoring flagsChanged events for
// the Control modifier (e.g., SpeakFlow's HotkeyListener).
//
// Requirements:
//   - The terminal (or parent app) must have Accessibility permission
//   - The target app must be running with its event tap active
//
// Usage:
//   swift scripts/simulate-double-tap-control.swift
//   swift scripts/simulate-double-tap-control.swift --tap cghid        (default)
//   swift scripts/simulate-double-tap-control.swift --tap session
//   swift scripts/simulate-double-tap-control.swift --tap annotated
//   swift scripts/simulate-double-tap-control.swift --delay 150        (ms between taps, default 200)
//   swift scripts/simulate-double-tap-control.swift --hold 50          (ms key hold duration, default 50)
//

import CoreGraphics
import Foundation

// MARK: - Configuration

/// Left Control virtual key code (0x3B = 59)
let controlKeyCode: CGKeyCode = 0x3B

/// Parse command-line arguments
func parseArgs() -> (tap: CGEventTapLocation, delayMs: UInt32, holdMs: UInt32, verbose: Bool) {
    var tap: CGEventTapLocation = .cghidEventTap
    var delayMs: UInt32 = 200
    var holdMs: UInt32 = 50
    var verbose = false

    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--tap":
            i += 1
            guard i < args.count else {
                fputs("Error: --tap requires a value (cghid, session, annotated)\n", stderr)
                exit(1)
            }
            switch args[i] {
            case "cghid":
                tap = .cghidEventTap
            case "session":
                tap = .cgSessionEventTap
            case "annotated":
                tap = .cgAnnotatedSessionEventTap
            default:
                fputs("Error: Unknown tap location '\(args[i])'. Use: cghid, session, annotated\n", stderr)
                exit(1)
            }
        case "--delay":
            i += 1
            guard i < args.count, let val = UInt32(args[i]) else {
                fputs("Error: --delay requires a numeric value in milliseconds\n", stderr)
                exit(1)
            }
            delayMs = val
        case "--hold":
            i += 1
            guard i < args.count, let val = UInt32(args[i]) else {
                fputs("Error: --hold requires a numeric value in milliseconds\n", stderr)
                exit(1)
            }
            holdMs = val
        case "--verbose", "-v":
            verbose = true
        case "--help", "-h":
            print("""
            Usage: simulate-double-tap-control.swift [OPTIONS]

            Simulates a double-tap of the Control key via CGEvent flagsChanged events.

            Options:
              --tap <location>   Event tap location: cghid (default), session, annotated
              --delay <ms>       Delay between first release and second press (default: 200)
              --hold <ms>        How long to hold the key down each tap (default: 50)
              --verbose, -v      Print detailed event information
              --help, -h         Show this help
            """)
            exit(0)
        default:
            fputs("Warning: Unknown argument '\(args[i])'\n", stderr)
        }
        i += 1
    }
    return (tap, delayMs, holdMs, verbose)
}

let config = parseArgs()

// MARK: - Event Source

/// Using .hidSystemState makes events appear to originate from the HID system,
/// which is what a real keyboard produces. This is important because event taps
/// created with .cgSessionEventTap see events from the HID level.
guard let eventSource = CGEventSource(stateID: .hidSystemState) else {
    fputs("Error: Failed to create CGEventSource. Check Accessibility permissions.\n", stderr)
    exit(1)
}

// MARK: - Event Creation and Posting

/// Creates and posts a Control key flagsChanged event.
///
/// Key insight: CGEvent(keyboardEventSource:virtualKey:keyDown:) with virtual key 0x3B
/// (left Control) automatically produces a flagsChanged event (CGEventType rawValue 12),
/// NOT a keyDown/keyUp event. The system recognizes modifier key codes and sets:
///   - type = .flagsChanged (12)
///   - flags includes .maskControl when keyDown=true
///   - flags excludes .maskControl when keyDown=false
///   - keyboardEventKeycode field = 59 (0x3B)
///
/// This is the correct way to simulate modifier-only key events. Do NOT use
/// CGEvent(source:) + manual type setting, as that misses internal HID fields
/// that CGEventCreateKeyboardEvent populates.
func postControlEvent(keyDown: Bool) {
    guard let event = CGEvent(
        keyboardEventSource: eventSource,
        virtualKey: controlKeyCode,
        keyDown: keyDown
    ) else {
        fputs("Error: Failed to create CGEvent for Control \(keyDown ? "down" : "up")\n", stderr)
        return
    }

    if config.verbose {
        let typeStr = keyDown ? "DOWN" : "UP  "
        let flagsHex = String(event.flags.rawValue, radix: 16)
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let hasControl = event.flags.contains(.maskControl)
        print("  \(typeStr) | type=\(event.type.rawValue) (flagsChanged) | flags=0x\(flagsHex) | keycode=\(keycode) | maskControl=\(hasControl)")
    }

    event.post(tap: config.tap)
}

func tapLocationName(_ tap: CGEventTapLocation) -> String {
    switch tap {
    case .cghidEventTap: return "cghidEventTap"
    case .cgSessionEventTap: return "cgSessionEventTap"
    case .cgAnnotatedSessionEventTap: return "cgAnnotatedSessionEventTap"
    @unknown default: return "unknown(\(tap.rawValue))"
    }
}

// MARK: - Simulate Double-Tap

print("Simulating double-tap Control key")
print("  Tap location: \(tapLocationName(config.tap))")
print("  Hold duration: \(config.holdMs)ms")
print("  Inter-tap delay: \(config.delayMs)ms")
if config.verbose {
    print()
}

// Tap 1: Control DOWN -> hold -> Control UP
if config.verbose { print("Tap 1:") }
postControlEvent(keyDown: true)
usleep(config.holdMs * 1000)
postControlEvent(keyDown: false)

// Inter-tap delay (must be < the listener's doubleTapInterval, typically 0.4s)
usleep(config.delayMs * 1000)

// Tap 2: Control DOWN -> hold -> Control UP
if config.verbose { print("Tap 2:") }
postControlEvent(keyDown: true)
usleep(config.holdMs * 1000)
postControlEvent(keyDown: false)

// Small delay to let the event propagate before the process exits
usleep(100_000)

print("Done.")
