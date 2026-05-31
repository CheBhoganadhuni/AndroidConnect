# Android Connect

A Mac menu-bar app paired with an Android companion app that turns your phone into a wireless file bridge — browse, transfer, and monitor your Android device from macOS over local Wi-Fi with no cables, no cloud, no accounts.

---

## What it does

| Feature | Detail |
|---|---|
| **File browser** | Full tree of your Android's storage in a native Mac window — grid or list view, thumbnails, search by type |
| **Download** | Double-click any file in the menu-bar popover or full browser to pull it to ~/Downloads |
| **Upload** | Drag files onto the menu-bar icon or the popover drop zone; they land in `/sdcard/AndroidConnect/` |
| **Battery** | Live battery level + charging state shown in the popover |
| **Notification mirror** | Phone notifications appear as macOS banners (optional, requires Notification Access) |
| **New-file alerts** | macOS notification when a new file appears on the phone; one-click "Save to Mac" action |
| **Auto-connect** | mDNS discovery — Mac finds the phone the moment the Android service starts, no IP configuration |
| **Auto-update** | Both apps check GitHub Releases on launch and self-install updates |

**Speed:** sustained 70–80 MB/s on 802.11ac Wi-Fi (256 KB transfer buffers, Darwin raw syscalls, progress callbacks throttled to 1 MB intervals so the IO thread is never interrupted).

---

## Inspiration

AirDrop works seamlessly between Apple devices. There is no equivalent for Android ↔ Mac. Every existing solution requires a USB cable, a cloud account, or a clunky third-party service with privacy implications. Android Connect is the AirDrop-like experience for the Android + Mac combination — fully local, zero-cloud, open source.

---

## Architecture

```
┌─────────────────────────────────┐        ┌──────────────────────────────────┐
│         macOS (Client)          │        │         Android (Server)          │
│                                 │        │                                  │
│  MenuBarController              │        │  ConnectService (Foreground)      │
│    │                            │        │    │                             │
│    ├─ DeviceDiscovery ──────────┼─mDNS──▶│    ├─ SocketServer (port 58000)  │
│    │   (NWBrowser / CFNetService)│        │    │   └─ dispatch() per command  │
│    │                            │        │    │                             │
│    ├─ SocketClient ─────────────┼─TCP────▶│    ├─ EventServer (port 58001)   │
│    │   └─ serial ioQueue        │        │    │   └─ push-only SSE stream    │
│    │                            │        │    │                             │
│    ├─ EventClient ──────────────┼─TCP────▶│    ├─ FileWatcher                │
│    │   └─ event push receiver   │        │    ├─ BatteryMonitor             │
│    │                            │        │    └─ NotificationService        │
│    ├─ MenuBarPopoverVC          │        │                                  │
│    └─ MainWindowController      │        │  FileManager                     │
│        └─ FileBrowserVC         │        │  Protocol.kt                     │
│                                 │        │  UpdateChecker.kt                │
│  UpdateChecker.swift            │        │                                  │
│  Protocol.swift                 │        │                                  │
└─────────────────────────────────┘        └──────────────────────────────────┘
```

---

### Mac side (Swift / AppKit)

The Mac app is a **menu-bar only** application — no Dock icon, no main window on launch. All code lives under `MacApp/Sources/AndroidConnect/`.

#### `AppDelegate.swift`
Entry point. Instantiates `MenuBarController` and keeps a strong reference.

#### `MenuBarController.swift`
The central orchestrator. Owns `DeviceDiscovery`, `SocketClient`, and `EventClient`. Wires their delegate callbacks together and drives the popover and full-window UI.

Key responsibilities:
- Starts mDNS discovery on launch
- Calls `client.connect(to:)` when a device is found
- Forwards socket delegate events (`dirListReceived`, `transferProgress`, etc.) to the file browser window
- Forwards event-channel callbacks (`batteryUpdated`, `fileCreatedOnPhone`, `notificationReceived`) to the UI and macOS notification center
- On disconnect: waits 3 s then restarts discovery automatically

#### `DeviceDiscovery.swift`
Wraps `NWBrowser` (Network framework) to browse for `_androidconnect._tcp.` mDNS services. When the Android service registers itself, `discoveryFound(_:)` fires and `MenuBarController` initiates the TCP connection.

#### `SocketClient.swift`
The TCP command channel (port 58000). All socket I/O runs on a single **serial `DispatchQueue`** (`com.androidconnect.io`) — this means commands are naturally serialised with no locking needed on the wire. The `fd` (raw POSIX socket descriptor) is protected by `NSLock` for reads from the main thread (`isConnected`, `disconnect`).

Key implementation details:
- `connect(to:)` opens a blocking TCP socket on the IO queue, sends `HELLO` with the Mac's computer name, then fires `clientConnected` on the main thread
- `downloadFile(path:)` sets `downloadPending = true` before enqueuing — `_recentFiles()` checks this flag and bails immediately so it doesn't block a queued download
- `thumbGeneration` counter: incremented on every transfer; thumbnail requests bail if the counter changed since they were enqueued
- File writes use `Darwin.write()` directly to a raw `fd` — no Foundation overhead
- Progress callbacks fire every 1 MB (not every chunk) so 32 000 `DispatchQueue.main.async` calls per 2 GB transfer don't saturate the main thread

#### `EventClient.swift`
A persistent TCP connection to port 58001 — a **push-only channel** where Android sends events without the Mac needing to poll. Events decoded on a background thread and dispatched to main:
- `battery` — level + charging state
- `file_created` — new file appeared on the phone
- `notification` — phone notification to mirror

#### `Protocol.swift` / `MessageProtocol`
Shared framing constants and helpers:
- **Framing:** 4-byte big-endian length prefix + UTF-8 JSON body
- **`bufferSize = 262 144`** (256 KB) — used for file transfer read/write loops
- **`connectSocket(host:port:)`** — sets `TCP_NODELAY` and 1 MB send/receive socket buffers before returning the fd
- `readMessage` / `writeMessage` — the only framing code; all commands go through these

#### `MenuBarPopoverViewController.swift`
The 310 × 270 pt popover attached to the status-bar button. Owns:
- Traffic-light buttons (red = quit, yellow = reconnect/rescan)
- `v1.0.x` version button → calls `UpdateChecker.shared.checkForUpdates(onBeforeResult:)`, shows "Checking…" immediately, closes popover only after result is ready
- Status dot + device name + battery
- 3-cell thumbnail row for the 3 most recent files (double-click to download)
- Transfer progress bar
- Drop zone overlay (shown on file drag)

#### `FileBrowserViewController.swift`
The full-window file browser. Uses `NSCollectionView` (grid) and `NSTableView` (list) backed by the same `[FileItem]` array. Double-click detection uses a `FileBrowserCollectionView` subclass that overrides `mouseDown(with:)` — calling `super` first means selection is always up to date when the double-click handler reads it (avoids the ~1 s gesture-recogniser disambiguation delay).

#### `UpdateChecker.swift`
Hits `https://api.github.com/repos/CheBhoganadhuni/AndroidConnect/releases/latest`. Compares the `tag_name` version against `AppVersion.current` using semantic versioning. On update:
1. Downloads the first `.zip` asset to `/tmp`
2. Writes a shell script to `/tmp/ac_install.sh` that (after the process exits): unzips, finds the `.app`, moves it over the old one, and calls `open` to relaunch
3. Runs the script detached, then calls `NSApp.terminate`

---

### Android side (Kotlin)

The Android app is a **foreground service** — the activity exists only for first-time permission setup. After that, the service runs indefinitely in the background. All code lives under `AndroidApp/app/src/main/java/com/connect/androidconnect/`.

#### `ConnectService.kt`
The foreground service that owns everything. On `onCreate` it wires up `SocketServer`, `EventServer`, `FileWatcher`, and `BatteryMonitor`. On `onStartCommand` it starts all four, registers the mDNS service, and sets up the `onConnect`/`onDisconnect` callbacks. The service is declared `START_STICKY` so Android restarts it if killed.

#### `SocketServer.kt`
Listens on port 58000. Accept loop runs on a cached thread pool. For each accepted socket it starts `handleClient()` on a pool thread, which loops reading messages and calling `dispatch()` until the socket closes.

Commands handled in `dispatch()`:

| Command | What it does |
|---|---|
| `HELLO` | Stores the Mac's computer name; one-way, no response |
| `PING` | Responds `PONG` |
| `STORAGE_INFO` | `StatFs` on external storage root |
| `LIST_DIR` | `File.listFiles()` sorted dirs-first |
| `GET_FILE` | Streams file bytes after `FILE_START` header |
| `PUT_FILE` | Receives bytes, writes to `/sdcard/AndroidConnect/`, triggers `MediaScanner` |
| `GET_DEVICE_INFO` | `Settings.Global.device_name` or `Build.MODEL` |
| `GET_THUMBNAIL` | Generates 160×160 JPEG thumbnail via `ThumbnailUtils`, returns base64 |
| `GET_RECENT_FILES` | `walkTopDown` the storage tree, sorted by `lastModified`, returns top N with thumbnails |
| `GET_FILE_COUNTS` | Counts files by extension across the tree |
| `GET_FILES_BY_TYPE` | Filters by extension set (images / videos / audio / documents / archives / apks) |
| `GET_FILES_BY_SOURCE` | Lists a named source folder (DCIM, Downloads, WhatsApp, Bluetooth) |

Error handling: `runCatching { dispatch(...) }` catches any `SocketException` from a mid-write socket closure and breaks the loop cleanly — the Mac closing the connection never crashes the Android service.

#### `EventServer.kt`
Listens on port 58001. Accepts one connection (the Mac's `EventClient`) and keeps a queue of JSON event strings. `push(event)` is called from any thread; the server flushes queued events over the open socket. If the socket drops, `onDisconnect` fires on `MenuBarController` which triggers reconnection.

#### `FileWatcher.kt`
Polls the external storage root periodically (or uses `FileObserver` where available) for newly created files. When a new file appears it pushes a `file_created` event to `EventServer`.

#### `BatteryMonitor.kt`
Registers a `BroadcastReceiver` for `ACTION_BATTERY_CHANGED`. On change it pushes a `battery` event (`level`, `charging`) to `EventServer`.

#### `NotificationService.kt`
Extends `NotificationListenerService`. When a notification is posted and `onNotification` is set (i.e. Mac is connected), it pushes a `notification` event with app label, title, and text.

#### `FileManager.kt`
Pure business logic — no Android framework knowledge. Implements all the file operations called by `SocketServer.dispatch()`. Thumbnail generation uses `ThumbnailUtils` for images and video; results are JPEG-compressed to base64. `safePath()` ensures all paths stay within the storage root (path traversal guard).

#### `Protocol.kt`
Mirrors `Protocol.swift`:
- `BUFFER_SIZE = 262 144` (256 KB) — used for `BufferedInputStream`/`BufferedOutputStream` wrapping the socket and for file I/O
- `readMessage` / `writeMessage` — same 4-byte length prefix + JSON framing

#### `UpdateChecker.kt`
Background thread on every app launch. Hits the same GitHub Releases API, compares `versionName` from `BuildConfig`, finds the first `.apk` asset. On update:
1. Shows a dialog ("Download & Install")
2. Downloads the APK to the app's cache dir
3. Uses `FileProvider` to get a `content://` URI
4. Fires `Intent.ACTION_VIEW` with `application/vnd.android.package-archive` — Android's system installer handles the rest

---

## Network protocol detail

```
Mac (client)                          Android (server)
     │                                      │
     │── TCP connect ──────────────────────▶│  port 58000
     │── {"cmd":"HELLO","macName":"…"} ────▶│  (one-way, no reply)
     │── {"cmd":"GET_DEVICE_INFO"} ─────────▶│
     │◀─ {"type":"DEVICE_INFO","model":"…"} ─│
     │── {"cmd":"GET_RECENT_FILES","limit":5}▶│
     │◀─ {"type":"RECENT_FILES","files":[…]} ─│
     │                                      │
     │── TCP connect ──────────────────────▶│  port 58001 (event push)
     │                    ◀── {"type":"battery","level":82,"charging":true}
     │                    ◀── {"type":"file_created","name":"…","path":"…"}
     │                    ◀── {"type":"notification","appLabel":"…","title":"…"}
```

Every message on both channels uses the same framing:
```
[ 4 bytes: big-endian uint32 body length ][ N bytes: UTF-8 JSON ]
```

File transfer (GET_FILE) after the initial JSON handshake sends raw bytes directly — no further framing — for the exact `size` declared in `FILE_START`. The Mac reads exactly `size` bytes using `Darwin.read` in 256 KB chunks.

---

## Releasing updates

Both Mac and Android updates live in the **same GitHub release**. There is no conflict because:
- The Mac updater looks for the first asset whose name ends in `.zip`
- The Android updater looks for the first asset whose name ends in `.apk`
- They are different files in the same release; each app ignores the other's asset

### Releasing a Mac update

```bash
# 1. Bump version in MacApp/Sources/AndroidConnect/AppVersion.swift
#    static let current = "1.0.2"
#    static let display = "v1.0.2"

# 2. Build
bash build_mac.sh

# 3. Zip the app bundle
zip -r AndroidConnect-v1.0.2.zip AndroidConnect.app

# 4. Publish (Mac-only release, no APK yet)
gh release create v1.0.2 \
  AndroidConnect-v1.0.2.zip \
  --title "v1.0.2" \
  --notes "What changed in this version"

# Done. Running Mac apps on v1.0.1 or earlier will detect the update
# on next launch and offer "Download & Restart".
```

### Releasing an Android update

```bash
# 1. Bump versionCode and versionName in AndroidApp/app/build.gradle
#    versionCode 2          ← always increment by 1
#    versionName "1.0.2"   ← match the release tag

# 2. Build
bash build_apk.sh

# 3. Rename APK so it's clearly identifiable
cp AndroidApp/app/build/outputs/apk/debug/app-debug.apk \
   AndroidConnect-v1.0.2.apk

# 4. Publish (add to the same release as the Mac zip, or as a separate release)
gh release create v1.0.2 \
  AndroidConnect-v1.0.2.zip \
  AndroidConnect-v1.0.2.apk \
  --title "v1.0.2" \
  --notes "What changed in this version"

# Or upload to an existing release:
gh release upload v1.0.2 AndroidConnect-v1.0.2.apk

# Done. Android users see "Update available: v1.0.2" on next app open.
# Tapping "Download & Install" fetches the APK and hands it to
# Android's system installer — no sideloading setup needed beyond
# the one-time "Allow from this source" prompt.
```

### Version numbering

Use standard semantic versioning: `MAJOR.MINOR.PATCH`

- `PATCH` (1.0.0 → 1.0.1): bug fixes
- `MINOR` (1.0.x → 1.1.0): new features, backwards-compatible
- `MAJOR` (1.x.x → 2.0.0): breaking protocol changes (both apps must update together)

> **Note:** GitHub's `/releases/latest` endpoint returns the most recently *published* release by date, not by version number. Always publish releases in version order. The `isNewer()` function in both updaters does real semantic comparison, so even if GitHub returns an unexpected version, the apps will never downgrade — they only install if the remote version number is strictly higher.

---

## Sharing with friends / Install guide

### What each person needs

| Scenario | Mac app | Android APK |
|---|---|---|
| Friend with their own Mac + Android | ✅ | ✅ |
| Friend who just wants to send you a file (you have the Mac app running) | ❌ | ✅ |

The APK alone is enough to connect to *any* running Mac app on the same network — the Mac app listens for anyone with the APK.

---

### Installing the Mac app

1. Go to **[github.com/CheBhoganadhuni/AndroidConnect/releases/latest](https://github.com/CheBhoganadhuni/AndroidConnect/releases/latest)**
2. Download `AndroidConnect-vX.X.X.zip`
3. Unzip → drag `AndroidConnect.app` to your `/Applications` folder
4. Double-click to open — macOS may warn "unidentified developer" since it's not notarised
   - Right-click → Open → Open (first launch only)
   - Or: System Settings → Privacy & Security → "Open Anyway"
5. The antenna icon appears in your menu bar — app is running

The app starts automatically on login once it has been run at least once (macOS remembers open-at-login apps that remain open).

---

### Installing the Android app

1. Go to **[github.com/CheBhoganadhuni/AndroidConnect/releases/latest](https://github.com/CheBhoganadhuni/AndroidConnect/releases/latest)** on your phone (or have someone AirDrop / share the APK)
2. Download `AndroidConnect-vX.X.X.apk`
3. Android will prompt **"Allow installs from this source"** — tap Allow
4. Tap Install when the system installer appears
5. Open Android Connect → tap **Start Service**
6. Grant permissions when prompted:
   - **Storage access** — required for file transfer (tap Allow in the app, then grant "All files access" in Settings)
   - **Notification Access** — optional, for notification mirroring (tap Enable → find Android Connect in the list → allow)

---

### Connecting

Both devices must be on the **same Wi-Fi network**, or the phone's **hotspot** with the Mac connected to it.

1. Mac app is running (antenna icon in menu bar)
2. Android app: tap **Start Service**
3. Within a few seconds the Mac popover shows a green dot + your device name and IP
4. Android app shows **"Mac connected"** with the Mac's computer name

No IP addresses, no pairing codes — mDNS handles discovery automatically.

---

### Switching between Android devices (one at a time)

Only one Android can be connected at a time. To switch:

**Option A — from the Mac:** tap the yellow circle in the popover header (Reconnect). The Mac drops the current connection and re-scans.

**Option B — from Android:** the current user taps **Stop Service** in their app. The new user opens Android Connect and taps **Start Service**. The Mac detects the disconnect and auto-reconnects to the new device within 3 seconds.

---

### Transferring files

**Download (Android → Mac)**
- **Menu bar:** open the popover, double-click a thumbnail in the Recent files row
- **Full browser:** click View › to open the file browser, double-click any file

**Upload (Mac → Android)**
- Drag any file onto the menu-bar antenna icon (popover opens as you drag near it)
- Or drag onto the open popover
- Or click ⬆ Transfer in the full browser toolbar and pick files

Files upload to `/sdcard/AndroidConnect/` on the phone and are immediately indexed by the Media Scanner so they appear in Gallery.

---

## Building from source

**Requirements:** Xcode Command Line Tools, Swift 5.9+, Android SDK with Gradle

```bash
git clone https://github.com/CheBhoganadhuni/AndroidConnect.git
cd AndroidConnect

# Mac app
bash build_mac.sh
open AndroidConnect.app

# Android APK (requires Android SDK; check build_apk.sh for Gradle path)
bash build_apk.sh
adb install AndroidApp/app/build/outputs/apk/debug/app-debug.apk
```

---

## Project structure

```
AndroidConnect/
├── MacApp/
│   └── Sources/AndroidConnect/
│       ├── AppDelegate.swift
│       ├── AppVersion.swift          ← bump before each Mac release
│       ├── UpdateChecker.swift
│       ├── network/
│       │   ├── Protocol.swift        ← framing, constants, socket setup
│       │   ├── SocketClient.swift    ← TCP command channel
│       │   ├── EventClient.swift     ← event push receiver
│       │   └── DeviceDiscovery.swift ← mDNS browser
│       └── ui/
│           ├── MenuBarController.swift
│           ├── MenuBarPopoverViewController.swift
│           ├── MainWindowController.swift
│           ├── FileBrowserViewController.swift
│           └── SidebarViewController.swift
├── AndroidApp/app/src/main/
│   ├── java/com/connect/androidconnect/
│   │   ├── MainActivity.kt
│   │   ├── UpdateChecker.kt
│   │   ├── BootReceiver.kt
│   │   └── service/
│   │       ├── ConnectService.kt
│   │       ├── SocketServer.kt       ← TCP command server
│   │       ├── EventServer.kt        ← event push server
│   │       ├── FileWatcher.kt
│   │       ├── BatteryMonitor.kt
│   │       └── NotificationService.kt
│   ├── res/layout/activity_main.xml
│   └── res/xml/file_paths.xml        ← FileProvider paths for APK install
├── build_mac.sh
├── build_apk.sh
└── README.md
```
