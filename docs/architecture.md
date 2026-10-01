# How DevSwitch works

```text
Mac menu bar ← encrypted local connection → Android companion
     │                                         │
     └── ADB + scrcpy over paired Wi-Fi ───→ Phone screen
```

The companion connection is independent of ADB, so it can turn debugging back on. Android polls the Mac on local TCP port 45874, applies fixed enable/disable actions, and returns settings readback. Enable switches on developer options, USB debugging, and wireless debugging; disable switches them off in reverse order and closes the mirror.

Pairing uses a five-minute QR invitation and a six-digit comparison. Commands and status are AES-256-GCM encrypted and authenticated over local HTTP. Request IDs, timestamps, and command expiry reject stale/replayed traffic. Keys use Mac Keychain and Android Keystore; Android backup is disabled. Network metadata remains visible. The protocol has not had an independent security audit.

Wireless ADB has separate Android authorization. The phone discovers its ADB address and sends it over the companion connection. Android 14+ subscribes to port updates. The Mac verifies the Android serial against its saved pairing before starting the separately installed scrcpy executable. Legacy unpaired TCP debugging on port 5555 is not used.

After an authenticated exchange, both apps prefer IPv6 link-local addresses on the same Wi-Fi interface. This avoids duplicate IPv4 addresses breaking the companion and screen connections. Android remembers the Mac's authenticated IPv6 address alongside its original IPv4 address and falls back to IPv4 when needed. Interface scope IDs are resolved locally, not copied between devices. Android uses a bounded HTTP socket for scoped IPv6 URLs, with the same encrypted protocol.

Automatic Mac rediscovery is not implemented. If both saved addresses change, pair again. Clocks must agree within 30 seconds. Foreground operation does not bypass Android Doze or manufacturer battery management.

## Source map

- `mac/DevSwitch.swift`: menu and settings UI.
- `mac/Controller.swift`, `Crypto.swift`, `HTTPServer.swift`: pairing, settings commands, local transport.
- `mac/ScreenControl.swift`, `BonjourDiscovery.swift`: ADB pairing, reconnection, scrcpy lifecycle.
- `mac/Dependencies.swift`: shared runtime and doctor dependency detection.
- `app/.../remote/`: Android pairing, background connection, protocol, endpoint tracking.
- `app/.../ui/`: Android dashboard and theme.

One phone pairs with each Mac app instance. The companion cannot execute arbitrary shell commands. Forgetting DevSwitch pairing does not revoke Android's separate ADB authorization.
