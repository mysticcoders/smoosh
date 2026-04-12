# Publishing Smoosh to the Mac App Store

Everything is in place code-wise. This guide covers the manual steps in Apple's portals to get the app listed and uploaded.

## Prerequisites

- Active Apple Developer Program membership (you have this -- Team ID: `REMBT6JY4N`)
- Xcode installed (for command-line tools)
- Access to [Apple Developer Portal](https://developer.apple.com/account) and [App Store Connect](https://appstoreconnect.apple.com)

## Step 1: Create Certificates

You already have a "Developer ID Application" certificate for direct distribution. The App Store requires two additional certificates.

1. Go to **developer.apple.com > Account > Certificates, Identifiers & Profiles > Certificates**
2. Click the **+** button to create a new certificate
3. Create both of these:
   - **Mac App Distribution** -- signs the app as "3rd Party Mac Developer Application"
   - **Mac Installer Distribution** -- signs the installer as "3rd Party Mac Developer Installer"
4. Download each certificate and double-click to install in your Keychain

Verify they installed:

```bash
security find-identity -v -p codesigning | grep "3rd Party"
```

You should see both identities listed.

## Step 2: Register the App ID

If you haven't already registered the bundle ID:

1. Go to **developer.apple.com > Account > Certificates, Identifiers & Profiles > Identifiers**
2. Click **+** to register a new identifier
3. Select **App IDs** > **App**
4. Fill in:
   - Description: `Smoosh`
   - Bundle ID (Explicit): `com.mystic.smoosh`
5. No additional capabilities are needed -- leave defaults
6. Click **Continue** then **Register**

## Step 3: Create a Provisioning Profile

1. Go to **developer.apple.com > Account > Certificates, Identifiers & Profiles > Profiles**
2. Click **+** to create a new profile
3. Select **Mac App Store** under Distribution
4. Select the `com.mystic.smoosh` App ID
5. Select your **Mac App Distribution** certificate
6. Name it something like `Smoosh App Store`
7. Download the profile
8. Save it as `Smoosh_AppStore.provisionprofile` in the Smoosh project root:

```bash
cp ~/Downloads/Smoosh_App_Store.provisionprofile ~/mystic/smoosh/Smoosh_AppStore.provisionprofile
```

## Step 4: Create the App in App Store Connect

1. Go to **appstoreconnect.apple.com > Apps**
2. Click **+** > **New App**
3. Fill in:
   - Platform: **macOS**
   - Name: `Smoosh`
   - Primary Language: English (U.S.)
   - Bundle ID: select `com.mystic.smoosh`
   - SKU: `smoosh-macos` (or any unique string)
4. Click **Create**

### App Information to fill in:

- **Subtitle**: `Compress images and video, instantly`
- **Category**: Graphics & Design
- **Content Rights**: Does not contain third-party content (libwebp and libvpx are open source BSD-licensed)
- **Age Rating**: 4+

### Pricing:

- Set pricing under **Pricing and Availability**
- Choose Free or set a price tier

### App Privacy:

- Smoosh does not collect any user data
- Under **App Privacy**, select **Data Not Collected**

## Step 5: Prepare Screenshots

App Store Connect requires at least one screenshot. You need screenshots for:

- **Mac** -- minimum 1280x800 or 1440x900

Take screenshots of the app in action:

1. Open Smoosh
2. Take a screenshot showing the main window (Cmd+Shift+4, select window)
3. Optionally take screenshots showing: drag-and-drop in progress, settings panel, compression results

Upload these under **App Store > macOS > Screenshots** in App Store Connect.

## Step 6: Build and Upload

Run the App Store build:

```bash
./build-appstore.sh
```

This will:
- Compile the app
- Embed the provisioning profile
- Sign with App Store certificates
- Create a `.pkg` installer

### Upload via Transporter (recommended):

1. Install **Transporter** from the Mac App Store (it's free, made by Apple)
2. Open Transporter
3. Drag `build-appstore/Smoosh.pkg` into the window
4. Click **Deliver**

### Or upload via command line:

```bash
xcrun altool --upload-app \
  -f build-appstore/Smoosh.pkg \
  -t macos \
  -u YOUR_APPLE_ID \
  -p @keychain:altool-password
```

To store your app-specific password in the keychain first:

```bash
xcrun altool --store-password-in-keychain-item "altool-password" \
  -u YOUR_APPLE_ID \
  -p YOUR_APP_SPECIFIC_PASSWORD
```

Generate an app-specific password at [appleid.apple.com](https://appleid.apple.com) > Sign-In and Security > App-Specific Passwords.

## Step 7: Submit for Review

1. Back in **App Store Connect > Your App**
2. Under **App Store > macOS**, select the build you just uploaded
3. Fill in the **What's New** section (for first release: describe what the app does)
4. Add a **Description**:

> Smoosh is a lightweight macOS utility that compresses images to WebP and optimizes video to MP4 or WebM. Drag and drop your files, and Smoosh handles the rest with sensible defaults -- 80% WebP quality, 1920px max width, 30fps, and 2.0 Mbps bitrate. All settings are adjustable. Native Swift app with no external dependencies. Under 2 MB.

5. Add **Keywords**: `compress, image, video, webp, mp4, webm, optimize, resize, convert, compression`
6. Fill in **Support URL**: `https://smoosh.wecodefire.com`
7. Click **Submit for Review**

## What to Expect from Review

Apple typically reviews within 24-48 hours. Common reasons for rejection on utility apps:

- **Sandbox violations** -- The entitlements file (`Smoosh.entitlements`) is already configured with sandbox + user-selected file access, so this should be fine
- **Minimum functionality** -- Smoosh has clear, useful functionality so this shouldn't be an issue
- **Metadata issues** -- Make sure screenshots match the actual app

## After Approval

Once approved, update the website:

1. Replace the "Coming soon to the Mac App Store" text with an actual Mac App Store badge
2. Add the App Store link

## Files Reference

| File | Purpose |
|------|---------|
| `build-appstore.sh` | App Store build script |
| `Smoosh.entitlements` | Sandbox entitlements |
| `Smoosh_AppStore.provisionprofile` | Provisioning profile (you download this) |
| `build.sh` | Direct distribution build (DMG) |
