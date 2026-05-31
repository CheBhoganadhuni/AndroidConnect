# Connection Troubleshooting — Android Connect

## How the connection works

1. **Android side** — `ConnectService` starts two TCP servers and registers an mDNS service:
   - Port `58000` — command/response socket (Mac → Android requests)
   - Port `58001` — push event channel (Android → Mac notifications)
   - mDNS service type: `_androidconnect._tcp.` advertised via Android NSD

2. **Mac side** — `DeviceDiscovery` browses for `_androidconnect._tcp.` on the local network. When found, `SocketClient` connects to port 58000 and `EventClient` connects to port 58001.

---

## Issue encountered: Phone in hotspot mode

### Symptom
Both apps running, both "searching for device", never connect.

### Diagnosis steps

```bash
# 1. Check if mDNS is advertising at all
dns-sd -B _androidconnect._tcp local.
# → Returned nothing

# 2. Check Android's network state
adb shell ip route
adb shell dumpsys wifi | grep -E "curState|mWifiInfo"
# → curState=DisconnectedState  (WiFi off)
# → ap0: 10.164.174.96          (hotspot interface active)

# 3. Confirm ports are actually reachable
nc -z -w3 10.164.174.96 58000   # → succeeded
nc -z -w3 10.164.174.96 58001   # → succeeded
```

### Root cause
Android's NSD (Network Service Discovery) registers mDNS on `wlan0` — the WiFi client interface. When the phone is in **hotspot mode** with WiFi off, `wlan0` is down. NSD never advertises on `ap0` (the hotspot interface), so the Mac's mDNS browser finds nothing — even though both devices are on the same subnet and the ports are fully reachable.

### Fix
Added a **5-second gateway fallback** to `DeviceDiscovery.swift` ([MacApp/Sources/AndroidConnect/network/DeviceDiscovery.swift](MacApp/Sources/AndroidConnect/network/DeviceDiscovery.swift)).

When the Mac is connected to the phone's hotspot, the **default gateway IS the phone** (e.g. `10.164.174.96`). If mDNS finds nothing in 5 seconds, the app reads the gateway from `route -n get default` and probes port 58000 directly.

```swift
// fires 5s after start() if mDNS hasn't found anything
fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
    self?.tryGatewayFallback()
}

private func tryGatewayFallback() {
    guard let gw = defaultGateway() else { return }
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let fd = MessageProtocol.connectSocket(host: gw, port: MessageProtocol.port)
        guard fd >= 0 else { return }
        Darwin.close(fd)
        let device = AndroidDevice(name: "Android", host: gw, port: Int(MessageProtocol.port))
        DispatchQueue.main.async { self?.delegate?.discoveryFound(device) }
    }
}
```

mDNS still runs in parallel — if mDNS responds first (normal WiFi scenario), it cancels the fallback timer and mDNS takes priority.

---

## Other things to check if not connecting

| Check | How |
|---|---|
| Android service running? | Look for persistent "Waiting for Mac…" notification on phone |
| Same network? | Mac and phone must be on the same subnet (WiFi or hotspot) |
| Firewall blocking? | `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add <binary>` |
| Fresh install didn't auto-start service | Open the Android app manually after `adb install` |

## Rebuild after any code change

```bash
# Android
bash build_apk.sh
adb install AndroidApp/app/build/outputs/apk/debug/app-debug.apk

# Mac
bash build_mac.sh
open AndroidConnect.app
```
