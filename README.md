# IPA Courier

A small macOS app that signs an `.ipa` with your Apple Developer account and
installs it on an iPhone or iPad connected by USB, with a progress bar.

## What it does

1. **Device**: detects iPhones and iPads plugged in over USB (through Apple's
   MobileDevice framework, the same one Finder and Xcode use) and shows the
   name, iOS version, Developer Mode state and free storage.
2. **App**: drop an `.ipa` on the window, click to choose one, or use
   Finder's *Open With → IPA Courier*.
3. **Signing**: picks a development certificate from your keychain and a
   provisioning profile that covers the device and bundle ID. If there isn't
   one, it builds (never installs) a tiny placeholder project with
   `xcodebuild -allowProvisioningUpdates -allowProvisioningDeviceRegistration`,
   so Xcode registers the device and downloads a profile.
4. **Sign & Install**: unpack (with byte-accurate progress), sign nested
   frameworks and extensions, then the app, and verify the signature. Next it
   checks the device's free space (app size + 1 GB margin) and installs with
   `devicectl`, showing its progress.

**Updating existing installs:** once an IPA and device are selected, IPA Courier
lists the device's apps. If the app is already installed, including under a
Sideloadly-style ID with your team ID appended (`com.example.app.ABCDE12345`),
it fills in that bundle ID so installing updates the existing copy and keeps
its data. A bundle ID you type yourself is never replaced. Buttons switch
between the existing copy's ID and the original ID.

If there isn't enough space, the signed copy is kept. Free up space, then
click **Re-check & Install** to skip signing. **Export Signed IPA…** saves the
signed app as an `.ipa`.

## Requirements

- Xcode, signed in to your Apple Developer account (Xcode → Settings → Accounts)
- Developer Mode on the device (Settings → Privacy & Security)
- Not sandboxed: it runs `codesign`, `xcodebuild`, `devicectl` and `unzip`

## Build

```bash
xcodegen generate
xcodebuild -project IPACourier.xcodeproj -scheme IPACourier -configuration Release -derivedDataPath build/dd build
open "build/dd/Build/Products/Release/IPA Courier.app"
```

Unpacked copies go in `~/Library/Caches/IPA Courier/Jobs`. They're removed
when you choose another IPA or quit, and on next launch. Profiles that
IPA Courier fetches are kept in `~/Library/Application Support/IPA Courier/Profiles`.

`Resources/ProvisioningStub` is the placeholder iOS project used to ask Xcode
for profiles.
