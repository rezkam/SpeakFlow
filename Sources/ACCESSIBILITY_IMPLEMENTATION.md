# Accessibility Permission Implementation

## Overview
This document explains the comprehensive accessibility permission handling system implemented in the dictation app.

## Key Features

### 1. **Early Permission Check**
- App checks accessibility permission immediately on launch
- Uses `AXIsProcessTrustedWithOptions()` with `kAXTrustedCheckOptionPrompt` to trigger system dialog on first run
- Logs permission status for debugging

### 2. **User-Friendly Alert Dialog**
When accessibility permission is not granted, the app shows a clear, informative alert that:
- Explains **why** the permission is needed (to insert dictated text)
- Provides **step-by-step instructions**
- Offers three options:
  - **"Open System Settings"** - Directly opens the Privacy & Security > Accessibility pane
  - **"Quit"** - Closes the app immediately
  - **"Remind Me Later"** - Dismisses the alert (permission can be granted later from menu)

### 3. **Direct Navigation to System Settings**
- Uses `x-apple.systempreferences:` URL scheme to open directly to:
  - **System Settings > Privacy & Security > Accessibility** (macOS 13+)
- This saves users from manually navigating through multiple settings panels

### 4. **Automatic Permission Detection**
- After user opens System Settings, app polls every 2 seconds to detect when permission is granted
- No manual refresh needed - app automatically detects the change
- Shows success notification when permission is granted

### 5. **Optional App Restart**
When permission is granted while app is running:
- Shows a success dialog
- Asks if user wants to restart the app (recommended for best compatibility)
- Offers two options:
  - **"Continue Without Restart"** - Keep using the app
  - **"Restart App"** - Automatically restarts the app for clean state

### 6. **Menu Bar Integration**
- Status icon shows current state:
  - 🎤 = Ready (permission granted)
  - ⚠️ = Warning (no permission)
  - 🔴 = Recording
  - ⏳ = Processing
- Menu includes "Enable Accessibility..." option that can be accessed anytime
- Menu item updates to show "✅ Accessibility Enabled" when permission is active

### 7. **Runtime Permission Check**
- When user tries to start dictation (⌃⌥D) without permission:
  - Plays error sound ("Basso")
  - Shows permission alert
  - Prevents recording from starting

### 8. **Active App Detection**
- Monitors when app becomes active (user returns from System Settings)
- Automatically updates UI to reflect current permission status
- Ensures status icon and menu are always accurate

## Implementation Details

### AccessibilityPermissionManager Class
New dedicated class that handles all permission-related logic:
- `checkAndRequestPermission()` - Main entry point for permission checks
- `showPermissionAlert()` - Displays the initial permission request dialog
- `openAccessibilitySettings()` - Opens System Settings to correct location
- `startPollingForPermission()` - Begins checking for permission changes
- `showPermissionGrantedAlert()` - Success notification with restart option
- `restartApp()` - Safely restarts the application

### AppDelegate Changes
- Added `permissionManager` property
- `applicationDidFinishLaunching()` now initializes permission manager first
- Added `applicationDidBecomeActive()` observer to detect app activation
- Added `updateStatusIcon()` to keep UI in sync
- Added `checkAccessibility()` menu action for manual permission check
- Enhanced `startRecording()` to verify permission before starting

## User Experience Flow

### First Launch
1. App launches
2. System shows built-in accessibility prompt (macOS standard dialog)
3. If user clicks "Deny" or dismisses:
   - App shows custom detailed alert
   - User can open System Settings or quit
4. If user grants permission:
   - App works immediately

### Permission Granted Later
1. User opens System Settings from app alert
2. Finds app in Accessibility list
3. Enables checkbox
4. Returns to app (or app detects in background)
5. App automatically detects permission within 2 seconds
6. Shows success alert asking about restart
7. User continues or restarts

### Attempting to Use Without Permission
1. User presses ⌃⌥D (or clicks "Dictate" menu)
2. App checks permission
3. If denied:
   - Plays error sound
   - Shows permission alert
   - Recording does not start

## Benefits

✅ **Clear Communication** - Users understand exactly what's needed and why
✅ **Minimal Friction** - Direct link to exact settings location
✅ **Automatic Detection** - No manual refresh or restart required
✅ **Always Accessible** - Can check/grant permission from menu bar anytime
✅ **Professional UX** - Matches behavior of popular Mac apps like:
   - Alfred
   - Rectangle
   - Magnet
   - BetterTouchTool

## Technical Notes

- Uses `AXIsProcessTrustedWithOptions()` instead of `AXIsProcessTrusted()` for initial check
- Polling timer is properly invalidated when permission is granted
- Weak references prevent retain cycles
- All UI updates happen on main thread
- Sound feedback for different states (error, start, stop, complete)

## Future Enhancements

Potential improvements for future versions:
- Add "Don't ask again" preference for users who want to use app without accessibility
- Show permission reminder after X failed attempts to use dictation
- Add detailed troubleshooting in a Help menu
- Support for checking permission via command-line argument (for automation)
