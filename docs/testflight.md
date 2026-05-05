# TestFlight Distribution

## App Store Connect

- Public App Store Connect name: **Saqoosha Pager**
- Installed app display name: **Pager**
- Main bundle ID: `sh.saqoo.pager-app`
- Notification Service Extension bundle ID: `sh.saqoo.pager-app.NotificationService`
- Team ID: `G5G54TCH8W`
- SKU: `sh.saqoo.pager-app`

The App Store Connect app record must exist before upload. If an
`xcodebuild -exportArchive` run fails with
`missingApp(bundleId: "sh.saqoo.pager-app")`, create the app in App Store Connect
first. The public name has to be globally unique, but it does not need to match
the installed `CFBundleDisplayName`.

## Build Requirements

Apple requires iOS/iPadOS apps uploaded to App Store Connect on or after
2026-04-28 to be built with the iOS 26 SDK or newer. The project still targets
iOS 17.0 for runtime deployment.

Verify the local toolchain before uploading:

```bash
xcodebuild -version
xcodebuild -showsdks
```

## Export Compliance

Both Info.plists include:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

This suppresses the per-build encryption compliance prompt for the current app.
It is appropriate because Pager uses Apple-provided `URLSession` HTTPS and
Keychain storage only. Re-evaluate this if the app adds custom cryptography,
VPN, encrypted messaging, DRM, or other encryption-focused features.

## Archive And Upload

Use a monotonically increasing build number. The timestamp format keeps
TestFlight uploads unique without editing project files.

```bash
BUILD_NUMBER=$(date +%Y%m%d%H%M)
ARCHIVE_DIR="/tmp/pager-testflight-$BUILD_NUMBER"
mkdir -p "$ARCHIVE_DIR"

xcodebuild archive \
  -project Pager.xcodeproj \
  -scheme Pager \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_DIR/Pager.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates
```

Create upload export options:

```bash
EXPORT_PLIST="$ARCHIVE_DIR/ExportOptions.plist"
EXPORT_PATH="$ARCHIVE_DIR/export"
mkdir -p "$EXPORT_PATH"

plutil -create xml1 "$EXPORT_PLIST"
plutil -insert method -string app-store-connect "$EXPORT_PLIST"
plutil -insert destination -string upload "$EXPORT_PLIST"
plutil -insert signingStyle -string automatic "$EXPORT_PLIST"
plutil -insert teamID -string G5G54TCH8W "$EXPORT_PLIST"
plutil -insert uploadSymbols -bool YES "$EXPORT_PLIST"
plutil -insert stripSwiftSymbols -bool YES "$EXPORT_PLIST"
plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_PLIST"
```

Upload:

```bash
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_DIR/Pager.xcarchive" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates
```

A successful upload ends with `Upload succeeded` and `EXPORT SUCCEEDED`.
App Store Connect processing can take several minutes before the build appears
under TestFlight.

## APNs Environment

Development installs from Xcode use sandbox APNs tokens. TestFlight and App
Store builds use production APNs tokens. Before testing a TestFlight build,
deploy the Worker with:

```toml
APNS_USE_SANDBOX = "false"
```

Switch it back to `"true"` for local development builds if the same Worker is
used for device installs from Xcode.

## After Upload

1. Open App Store Connect -> **Saqoosha Pager** -> **TestFlight**.
2. Wait for processing to finish.
3. Add the build to an internal tester group.
4. For external testers, add the build to an external group and submit it for
   Beta App Review.
5. Send a test notification from the app after installing from TestFlight. If it
   fails, check the Worker APNs environment first.

## Troubleshooting

- `missingApp(bundleId: "sh.saqoo.pager-app")`: create the App Store Connect app
  record before uploading.
- App name unavailable: pick a globally unique ASC name such as
  `Saqoosha Pager`; keep `CFBundleDisplayName` as `Pager`.
- Export compliance prompt appears: confirm both Info.plists contain
  `ITSAppUsesNonExemptEncryption = false`, then upload a new build.
- TestFlight install receives no pushes: verify the Worker is using production
  APNs with `APNS_USE_SANDBOX = "false"`.
