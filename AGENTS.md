<claude-mem-context>
# Memory Context

# [Pager] recent context, 2026-05-01 8:14pm GMT+9

Legend: 🎯session 🔴bugfix 🟣feature 🔄refactor ✅change 🔵discovery ⚖️decision
Format: ID TIME TYPE TITLE
Fetch details: get_observations([IDs]) | Search: mem-search skill

Stats: 27 obs (9,818t read) | 144,814t work | 93% savings

### May 1, 2026
400 7:53p 🔵 Pager iOS Project Structure and Xcode Environment
401 " 🔵 Pager iOS App Build Configuration Details
402 7:54p 🔵 Pager Xcode Project Has Malformed Group Membership Warning
403 " 🔵 Pager App Entitlements and Capabilities Configuration
404 7:55p 🔵 Pager Release Config Uses "iPhone Developer" Identity — Wrong for Distribution
405 " 🟣 Pager Release Archive Build Started Successfully
406 " 🟣 Pager Release Archive Completed Successfully
407 7:56p 🔵 xcodebuild exportOptionsPlist Key Reference for TestFlight Distribution
408 " 🔵 xcodebuild exportArchive Failed: "Error Downloading App Information"
409 " 🔵 Export Failure Root Cause: App Record Missing in App Store Connect
410 " 🔵 No Apple Distribution Certificate in Keychain — Required for TestFlight Upload
411 7:57p 🔵 App Store Connect Browser Session Not Authenticated; Multiple Xcode Developer Teams Present
412 " 🔵 Fastlane Installed; Personal sh.saqoo.* Apps Already Distributed
413 7:58p ⚖️ Use fastlane produce to Create Missing App Store Connect Record for Pager
414 " 🔵 Three App Store Connect Teams on Account; No Stored Fastlane Credentials
415 " 🔵 fastlane produce Authentication Failed: saqoosha@whatever.co Not the Apple ID for Team G5G54TCH8W
416 7:59p 🔵 Xcode DeveloperPortal SQLite Databases Contain Account and Team Info
417 " 🔵 Apple ID for Personal Team G5G54TCH8W Found: a@saqoo.sh
418 8:03p 🔵 Second exportArchive Attempt Still Fails: App Record Still Not Created in App Store Connect
419 " 🟣 Pager.ipa Upload to App Store Connect Started Successfully
420 8:04p 🟣 Pager 1.0.0 Build 202605011954 Successfully Uploaded to App Store Connect/TestFlight
421 8:05p 🟣 Pager 1.0.0 Build 202605011954 Upload Confirmed Clean: "UPLOAD SUCCEEDED with no errors"
422 " ✅ Complete TestFlight Distribution Workflow for Pager iOS App Documented
423 " 🔵 Pager Uses Only Standard URLSession HTTPS — Exempt from Export Compliance
424 8:06p 🔵 Pager NetworkService Architecture: Bearer Token Auth via Keychain, No Custom Crypto
425 " 🔵 KeychainHelper Uses kSecAttrAccessibleAfterFirstUnlock for Notification Extension Access
426 " ✅ Added ITSAppUsesNonExemptEncryption=false to Both Info.plist Files

Access 145k tokens of past work via get_observations([IDs]) or mem-search skill.
</claude-mem-context>

## Project Notes

- TestFlight/App Store Connect app name: **Saqoosha Pager**. The installed app
  still displays as **Pager** from `CFBundleDisplayName`.
- Bundle IDs: main app `sh.saqoo.Pager`; Notification Service Extension
  `sh.saqoo.Pager.NotificationService`.
- App Store Connect uploads require the app record to exist before running
  `xcodebuild -exportArchive`. If export fails with
  `missingApp(bundleId: "sh.saqoo.Pager")`, create the ASC app record first.
- TestFlight builds use production APNs. Set Worker var
  `APNS_USE_SANDBOX = "false"` before testing a TestFlight install.
- Export compliance is predeclared with
  `ITSAppUsesNonExemptEncryption = false` in both Info.plists. This assumes the
  app continues to use only standard `URLSession` HTTPS and Keychain storage,
  without custom cryptography.
