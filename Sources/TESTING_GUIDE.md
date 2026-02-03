# Testing Guide: Accessibility Permission Implementation

## Test Scenarios

### 1. First Launch (No Permission)

**Setup:**
- Build and run the app for the first time
- Accessibility permission has never been granted

**Expected Behavior:**
1. macOS shows system accessibility prompt
2. If user denies or dismisses:
   - App shows custom alert with detailed instructions
   - Status bar icon shows ⚠️ (warning)
   - Menu shows "⚠️ Enable Accessibility..."

**Test Actions:**
- Click "Open System Settings" → Should open Privacy & Security > Accessibility
- Click "Quit" → App should terminate immediately
- Click "Remind Me Later" → Alert dismisses, app continues with ⚠️ icon

---

### 2. Granting Permission from System Settings

**Setup:**
- App is running without permission
- User clicked "Open System Settings"

**Expected Behavior:**
1. System Settings opens to Accessibility pane
2. User finds app in list and enables checkbox
3. Within 2 seconds:
   - App detects permission
   - Logs: "✅ Accessibility permission granted!"
   - Shows success alert asking about restart
   - Status icon changes from ⚠️ to 🎤

**Test Actions:**
- Click "Continue Without Restart" → App continues, icon is 🎤
- Click "Restart App" → App relaunches, everything works

---

### 3. Using Dictation Without Permission

**Setup:**
- App running without accessibility permission

**Test Actions:**
- Press ⌃⌥D (hotkey)
- Click "Dictate" in menu

**Expected Behavior:**
- Plays "Basso" error sound
- Shows permission alert (same as first launch)
- Recording does NOT start
- Status icon remains ⚠️

---

### 4. Using Dictation With Permission

**Setup:**
- App has accessibility permission

**Test Actions:**
- Press ⌃⌥D to start
- Speak some text
- Press ⌃⌥D to stop

**Expected Behavior:**
- Icon changes: 🎤 → 🔴 → ⏳ → 🎤
- Plays sound: Pop → (silence) → Blow → (processing) → Glass
- Text is inserted into focused application
- Logs show successful transcription

---

### 5. Checking Permission from Menu

**Setup:**
- App is running (with or without permission)

**Test Actions:**
- Click menu bar icon
- Click "Enable Accessibility..." or "✅ Accessibility Enabled"

**Expected Behavior:**

**If permission is granted:**
- Shows alert: "Accessibility Permission Active"
- Informative message confirms permission is working
- Single "OK" button

**If permission is NOT granted:**
- Shows full permission request alert
- Same as first launch flow

---

### 6. Returning to App from System Settings

**Setup:**
- User went to System Settings to enable permission
- User clicks app icon or switches back via Cmd+Tab

**Test Actions:**
- Grant permission in System Settings
- Return to app (without clicking in app)
- Wait 2 seconds

**Expected Behavior:**
- App detects activation via `applicationDidBecomeActive`
- Re-checks permission status
- Updates UI automatically
- Shows success alert if permission was just granted

---

### 7. Permission Revocation

**Setup:**
- App is running WITH permission
- User revokes permission in System Settings

**Test Actions:**
- While app is running, go to System Settings
- Disable app in Accessibility list
- Return to app
- Try to use dictation

**Expected Behavior:**
- When app becomes active: icon changes to ⚠️
- Menu item updates to "⚠️ Enable Accessibility..."
- Attempting to dictate shows permission alert
- Recording does not start

---

## Manual Testing Checklist

### Initial State
- [ ] App launches successfully
- [ ] Permission check runs immediately
- [ ] System prompt appears (first time only)
- [ ] Status icon shows correct state (🎤 or ⚠️)

### Alert Dialogs
- [ ] Permission alert shows clear instructions
- [ ] Alert has warning icon (⚠️)
- [ ] Three buttons work correctly
- [ ] Success alert shows on permission grant
- [ ] Success alert has checkmark icon (✅)
- [ ] Restart option works

### System Settings Integration
- [ ] "Open System Settings" opens correct pane
- [ ] App appears in Accessibility list
- [ ] Enabling checkbox is detected within 2s
- [ ] Disabling checkbox is detected on app activation

### Menu Bar
- [ ] Icon changes based on state
- [ ] Menu shows correct permission status
- [ ] "Enable Accessibility" menu item works
- [ ] Menu item text updates when permission changes

### Dictation Functionality
- [ ] Cannot dictate without permission
- [ ] Can dictate with permission
- [ ] Error sound plays when blocked
- [ ] Success sounds play when working

### Edge Cases
- [ ] Multiple rapid permission checks don't crash
- [ ] Polling timer is properly invalidated
- [ ] App doesn't hang if Settings never opened
- [ ] Restart works from bundled app
- [ ] Works in both Debug and Release builds

---

## Automated Testing Ideas

```swift
// Unit tests for permission manager
class AccessibilityPermissionTests {
    func testInitialState() {
        let manager = AccessibilityPermissionManager()
        // Should not crash on init
    }
    
    func testCheckPermission() {
        let manager = AccessibilityPermissionManager()
        let result = manager.checkAndRequestPermission(showAlertIfNeeded: false)
        // Result should be Bool
    }
    
    func testPollingStops() {
        let manager = AccessibilityPermissionManager()
        manager.stopPolling()
        // Should not crash
    }
}
```

---

## Known Limitations

1. **System Prompt Only Shows Once**
   - macOS only shows built-in prompt on first check
   - Subsequent checks must rely on custom alert

2. **Settings Deep Link**
   - URL scheme works on macOS 10.15+
   - Older versions may not open exact pane

3. **Restart Functionality**
   - Requires app to be in /Applications or known location
   - Command-line builds may not restart correctly

4. **Permission Detection Delay**
   - 2-second polling interval
   - Not instant but avoids excessive checks

---

## Troubleshooting

### Alert Doesn't Appear
- Check: Is app in foreground?
- Check: Is `showAlertIfNeeded` set to `true`?
- Check: Has alert already been shown?

### System Settings Doesn't Open
- Check: macOS version compatibility
- Check: URL scheme is correct
- Try: Open manually and check app appears in list

### Permission Not Detected
- Check: Is polling timer running?
- Check: Is app actually in Accessibility list?
- Check: Try clicking app icon to trigger activation check

### Restart Fails
- Check: App bundle path is valid
- Check: App is not running from Xcode's DerivedData
- Check: `/usr/bin/open` has permissions

---

## Logging Guide

Key log messages to watch for:

```
✅ Accessibility permission granted      // Permission detected
⚠️ No Accessibility permission          // Missing permission
⚠️ User postponed accessibility         // Clicked "Remind Me Later"
🔓 Opened System Settings                // Settings opened
🔄 Restarting app...                     // Restart initiated
⏳ Rate limit: waiting X.Xs              // API throttling
🎤 Chunk (reason): X.Xs, Y% speech      // Audio chunk sent
📝 Output: "text"                        // Transcription received
✅ #X: "text"                            // Successful API call
❌ #X: error                             // Failed API call
```

---

## Best Practices for Users

### Recommended Setup Flow
1. Launch app for first time
2. Click "Open System Settings" when prompted
3. Enable app in Accessibility list
4. Return to app
5. Choose "Restart App" when asked
6. Test with ⌃⌥D in TextEdit

### If Permission Was Denied
1. Click menu bar icon (⚠️)
2. Click "⚠️ Enable Accessibility..."
3. Follow on-screen instructions
4. Return to app (auto-detected)

### For Troubleshooting
1. Check menu bar icon status
2. Try manual permission check from menu
3. Verify app appears in System Settings list
4. Restart app if permission recently granted
5. Check Console.app for log messages

