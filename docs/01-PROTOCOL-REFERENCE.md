# Protocol Reference — Carbit EasyConnect / PXC (for the Swift port)

This is the condensed, byte-exact reference for implementing the networking layer in Swift. It is
extracted from the Android project's `docs/01-REVERSE-ENGINEERING.md` (full version in
`../reference/android-docs/01-REVERSE-ENGINEERING.md`) and cross-checked against the actual working
Kotlin source (`../reference/android-source/java/dev/zanderp/opencfmoto/PxcFrame.kt` and
`PxcHandshake.kt`). Treat every value here as **verified against real hardware**, not a hypothesis.

**Target bike: CFMoto Aura 150.** No CLIENT_INFO capture exists yet for this exact model — it is presumed
CFDL16-class (same generation/family as the confirmed CFDL16 "675 SR-R" unit below: 5" landscape,
non-touch, handlebar buttons only) based on `docs/SUPPORTED-BIKES.md`. **Treat the CFDL16 profile as the
default/primary target, but implement `BikeProfile` as a strategy so the phone auto-adapts from whatever
CLIENT_INFO the Aura 150 actually sends on first connect** — do not hardcode assumptions that would break
if the Aura 150's firmware turns out to diverge slightly (e.g. a different `sdkVersion` or resolution).
The first real bike test's captured log is the source of truth for anything marked ⚠️ below.

## 0. Hardware assumptions for Aura 150

- Landscape, **800×386** non-touch display (unconfirmed for Aura 150 specifically — verify on first
  connect; `REQ_RV_CONFIG_CAPTURE` payload will report the bike's actual `deviceWidth`/`deviceHeight`).
- `socketTimeoutPeriodWifi = 9` — **the bike drops the media connection if no frame arrives within ~9s.**
  The very first frame after connect must arrive fast. This is the single most important timing
  constraint in the whole system.
- No touch — all interaction is via Bluetooth handlebar remote (AVRCP-style) or the phone's own UI.

## 1. The pairing QR code

Shown on the bike's dash. A URL with a query string:

```
http://www.carbit.com.cn/downsdk/657/658/_sdk?modelid=37416&sn=peTz&action=9
   &ssid=CFMOTO-f46457&pwd=59a9cddc94&auth=wpa2-psk
   &mac=6C:09:4A:0F:6C:F8&name=CFMOTO-f46457
```

Parse with a simple `URLComponents` query-item extraction:
- `ssid` / `pwd` / `auth` / `mac` / `name` — stable Wi-Fi AP credentials. Persist these per-bike.
- `sn` — random nonce, changes every scan, **not used** in the connection flow. Ignore.
- `modelid` — coarse bike identity, usable to pre-select a `BikeProfile` before CLIENT_INFO arrives.
- `action` — bitmask of supported transport modes (bit0 = AP, bit1 = AP+internet, bit3 = P2P/WiFi-Direct,
  bit6 = BT). **v1 targets AP mode only** (bit0) — join the SSID directly, ignore P2P.

Swift model: `QrData` struct with `ssid`, `password`, `auth`, `mac`, `name`, `modelId`, decoded via
`URLComponents(string:)?.queryItems`.

## 2. Network topology — **the phone is the TCP server**

This is the single most important architectural fact. The phone does NOT dial into the bike's app
server; the phone opens listening sockets and the bike dials in.

1. Phone joins the bike's Wi-Fi AP (from QR: SSID/password, WPA2, **no internet access** — expect this,
   don't treat lack of internet as an error). Bike is gateway, typically `192.168.0.1`; phone gets an
   address on the same /24 (e.g. `192.168.0.50`).
2. Phone discovers the bike via mDNS `_EasyConn._tcp.local.` (TXT record has huid/huname/channel/
   flavor/port/ip) — **or simply use the gateway IP + port 10930 directly** if mDNS resolution is flaky
   (the Android app falls back to this; do the same in Swift — don't make mDNS a hard dependency).
3. **Phone opens three TCP listen sockets**: `10920`, `10921`, `10922`, bound to the phone's
   bike-network interface address (not `0.0.0.0` broadly — bind to the specific bike-network IP so this
   doesn't collide with any other network interface).
4. Phone makes **one outbound connection** to `bike:10930`, sends a probe frame, reads the ack, **closes
   that socket**.
5. **The bike then connects back** to the phone's three listening ports and drives the entire handshake
   and media pull from there. The phone only ever *responds* from this point on.

Port roles (framing differs per port — decode by which port the connection landed on):

| Port | Role | Framing |
|-----:|------|---------|
| 10922 | PXC control (channel select, CLIENT_INFO, SN check, heartbeats) | **CmdBaseHead** (16-byte header) |
| 10921 | Media control (capture config, start/stop) | **ReqBase** (8-byte header) |
| 10920 | Media data (the actual H.264 frame pulls) | **ReqBase** (8-byte header), but frame *replies* are raw |
| 10930 | Bike's own probe/mDNS endpoint (phone dials out here once, then never again) | **CmdBaseHead** |

Swift networking approach: `NWListener` on each port, `NWConnection` per accepted inbound socket. Do NOT
use `URLSession` — this is raw TCP framing, not HTTP.

## 3. CmdBaseHead framing (port 10922, and the one-shot probe to 10930)

16-byte header, **little-endian**, immediately followed by the payload:

```
offset  0 : cmd       Int32   (command ID)
offset  4 : totalLen  Int32   (= 16 + payload.count)
offset  8 : magic     Int32   (= cmd ^ totalLen — integrity check; the bike DROPS the
                                connection on a mismatch, so get the XOR right)
offset 12 : reserved  Int32   (always 0 on write; ignore on read)
payload[totalLen - 16] bytes  (usually UTF-8 JSON; empty for most acks)
```

Swift struct:
```swift
struct PxcFrame {
    let cmd: Int32
    let payload: Data

    func encoded() -> Data {
        let totalLen = Int32(16 + payload.count)
        let magic = cmd ^ totalLen
        var header = Data(capacity: 16)
        header.append(littleEndian: cmd)
        header.append(littleEndian: totalLen)
        header.append(littleEndian: magic)
        header.append(littleEndian: Int32(0))
        return header + payload
    }
    // decoded(from:) reads the same 16 bytes, verifies magic == cmd ^ totalLen,
    // and returns nil (log + close the connection) on mismatch — mirroring the
    // Kotlin PxcFrame contract exactly.
}
```

### Control-plane exchange sequence (all payloads JSON unless noted)

Run this exactly in order; the bike drives it, the phone only replies per-cmd:

1. **Probe** (phone → bike:10930): `cmd = 0x70000010` (ECP_PXC_MDNS_RESPOND), payload
   `{"phoneType":"iOS","packageName":"com.amielsena.auralink"}`. Bike replies `cmd = 0x70000011`,
   `{"status":true}` (or `false` to reject — treat as a hard failure, surface to the user). Close this
   socket immediately after the reply.
2. Bike connects to `:10922`, sends `cmd = 0x10000` (CAR_CTRL channel select, empty payload) → phone
   replies `cmd = 0x10001` (empty). **Start a heartbeat responder on THIS socket** (see step 7).
3. Bike sends `cmd = 0x10010` **CLIENT_INFO** (JSON — bike's identity: `HUID`, `HUName`, `channel`,
   `flavor`, `sdkVersion`, `socketTimeoutPeriodWifi`, `supportScreenMirroring`, etc. — **capture and log
   this verbatim on first Aura 150 connect**, it's the ground truth for whether the CFDL16 profile
   assumption holds). Phone replies `cmd = 0x10011` with the phone's own CLIENT_INFO:
   ```json
   {"pxcVersion":"1.0.2","phoneUUID":"<uuid, generate+persist per install>",
    "phoneBrand":"Apple","phoneModel":"<UIDevice model>","phoneOsVersion":"<UIDevice systemVersion>",
    "phoneOs":"iOS","package":"com.amielsena.auralink","versionCode":1,"token":0,
    "pubkey":"<RSA public key, X.509 SPKI, base64>",
    "encryptedHUID":"<bike's HUID, RSA-signed with our private key, base64>",
    "bluetoothName":"AuraLink","supportH264IFrame":true,"supportFunction":0,
    "appVersionFingerPrint":"<short build id>"}
   ```
   RSA: generate a 2048-bit RSA keypair on first launch (SecKeyCreateRandomKey), persist in Keychain.
   `encryptedHUID` = sign the bike's HUID string bytes with the private key (SecKeyCreateSignature,
   PKCS1v15), base64-encode.
4. Bike `cmd = 0x10690` `{"usbSpeed":0,"wifiSpeed":0}` → phone `cmd = 0x10691` (empty).
5. **Second** bike connection to `:10922`: `cmd = 0x20000` (CAR_DATA channel select) → phone
   `cmd = 0x20001`. **Start a heartbeat responder on this second socket too** — the Android project
   learned the hard way (800NK ~7s flap) that leaving either `:10922` channel socket without a proactive
   heartbeat causes a drop; heartbeat BOTH.
6. **SN check**: bike `cmd = 0x103e0` `{"client_set":"easy_conn","sn":"<bike serial>"}` → phone
   `cmd = 0x103e1` (empty ack), then phone proactively sends `cmd = 0x201c0`
   `{"isOk":true,"errCode":0,"errMsg":"","id":"<echo sn>","client_set":"easy_conn"}` → bike acks
   `cmd = 0x201c1`.
7. **Heartbeats**: bike sends `cmd = 0x70000000` periodically on each `:10922` socket → phone replies
   `cmd = 0x70000001` (empty), immediately. Also proactively send a heartbeat every ~2s from the phone
   side on each channel socket (don't only reply — the Android app runs a proactive 2s heartbeat timer
   per channel socket; replicate that, it's what fixed the 800NK flap).

Any other `cmd` received on `:10922` that isn't in this list: log it (hex + JSON text if parseable) and
do NOT reply unless a `BikeProfile` variant specifically handles it (see §7 in the full doc for CFDL26's
extra post-SN notify burst — likely N/A for Aura 150/CFDL16, but log unknowns anyway in case the Aura 150
turns out to send something CFDL16 didn't).

## 4. ReqBase framing (media plane — ports 10921 + 10920)

8-byte header, little-endian, then body:

```
offset 0 : cmdType  Int16
offset 2 : cmdLen   UInt16   (body length)
offset 4 : token    Int32
body[cmdLen] bytes
```

| cmdType | name | direction | reply |
|--------:|------|-----------|-------|
| 16 | REQ_RV_CONFIG_CAPTURE | bike→phone | 17 |
| 48 | REQ_GET_VERSION | bike→phone | 49 (two Int32: version, 1) |
| 64 | REQ_HEARTBEAT | bike→phone | 65 (empty) |
| 96 | REQ_CONFIGCAPTUREREXTEND | bike→phone | 97 (JSON `{"state":0}`) |
| 112 | REQ_RV_DATA_START | bike→phone | 113 (empty) — **this is the "start the encoder now" signal** |
| 114 | REQ_RV_DATA_NEXT | bike→phone, on the **data** socket (:10920) | one raw H.264 frame (below) |

### REQ_RV_CONFIG_CAPTURE (16) body — little-endian

```
deviceWidth            Int16  @0    (bike's requested width — VERIFY against Aura 150's real value)
deviceHeight           Int16  @2    (bike's requested height)
wantFps                Int32  @4
wantEncoder            Int32  @8    (2 = H.264)
supportCodec           Int32  @12
minQuality              Int16  @16
maxQuality              Int16  @18
bitRate                 Int32  @20
capScreenMode           UInt8  @24
touchMode               UInt8  @25
orientation             UInt8  @26
displayId               UInt8  @27
videoType               UInt8  @28
supportExtendProtocol   UInt8  @29
reserved                2 bytes @30
encryptedHUID           UTF-8 string, rest of body
```

Reply **RLY_RV_CONFIG_CAPTURE (17)** body:
```
encoder                 Int32   (echo wantEncoder — send 2)
captureWidth            Int16   (deviceWidth  rounded DOWN to a multiple of 16 — `w & ~15`)
captureHeight           Int16   (deviceHeight rounded DOWN to a multiple of 16 — `h & ~15`)
supportExtendProtocol   UInt8   (echo)
```

This is where the ACTUAL encoder resolution gets decided — not a hardcoded 800×384. **Configure the
`VTCompressionSession` lazily, only after this exchange**, using the rounded `captureWidth`/`captureHeight`,
exactly like the Android `VideoPipeline.configureBikeCanvas()` does.

### The data pull (lock-step) — port 10920

Bike sends `REQ_RV_DATA_NEXT` (cmdType 114, empty body) and blocks waiting for exactly one frame; the
instant it receives one it sends the next `114`. **The frame reply is raw, NOT wrapped in a ReqBase
header:**

```
[ frameSize : Int32 LE ][ H.264 Annex-B access unit, frameSize bytes ]
```

SPS/PPS (codec config) must be prepended to the bytes of the first keyframe sent after connect, so the
bike's decoder can cold-start mid-stream.

⚠️ **Flagged as inferred-not-100%-confirmed even in the mature Android app.** If frames don't render on
first Aura 150 test, this exact byte layout (especially whether a trailing terminator is needed) is the
first thing to re-verify from a captured log — treat it as the prime suspect for a black-screen bug, not
the PXC control handshake (which is thoroughly confirmed).

## 5. The H.264 encoder contract (what the bike's decoder expects)

Configure `VTCompressionSession` to match, as closely as VideoToolbox allows:

- Resolution: from `RLY_RV_CONFIG_CAPTURE` (§4) — expect ~800×384, but **use the negotiated value**, do
  not hardcode.
- Profile: **Baseline @ Level 3.1** (`kVTProfileLevel_H264_Baseline_3_1`). Embedded head-unit decoders
  are frequently Baseline-only; if VideoToolbox produces artifacts, this is the first setting to
  double-check — do NOT silently fall back to a higher profile the way you might for a desktop player.
- Bitrate: **2.5 Mbps** default target (this becomes the ceiling for the adaptive controller — see
  `02-IOS-ARCHITECTURE-PLAN.md`).
- Frame rate: **30 fps** target (also the ceiling for adaptive stepping).
- Keyframe interval: **1 second** (`kVTCompressionPropertyKey_MaxKeyFrameInterval` = fps, or
  `...Duration` = 1.0).
- **Critical: repeat-last-frame behavior.** Android's `MediaCodec` needs an explicit
  `KEY_REPEAT_PREVIOUS_FRAME_AFTER` flag because surface-input encoders only emit on new buffers — a
  static map produces zero frames and the bike's 9s socket timeout kills the link. **VideoToolbox with a
  pixel-buffer-pool input has the same problem**: if the MapKit view isn't redrawing (stopped at a
  light, straight highway), you MUST manually re-submit the last rendered frame to the compression
  session on a timer (~900ms interval — matches the Android app's idle-throttle tuning, see
  `AdaptiveVideoController` idea in the Android `06-OPTIMIZATION-IDEAS.md`) or the bike will disconnect
  every time the map is static. **This is not optional — treat it as a P0 requirement, not a
  polish item.**
- Output is Annex-B (start-code prefixed); VideoToolbox emits AVCC/length-prefixed NALUs by default —
  **you must convert** (strip the 4-byte length prefix, insert `00 00 00 01` start codes) before sending
  to the bike. Capture SPS/PPS from the format description and prepend to the first keyframe's Annex-B
  bytes.

## 6. BLE wake-up — SKIP for v1

Not required for projection (confirmed dormant-safe in the Android app). The bike also advertises BLE
services (wake-up, and on some units an audio module — see `../reference/android-docs/RE-VEHICLE-TELEMETRY.md`),
but none of it is needed to get navigation on the dash. **Do not implement CoreBluetooth for this app's
v1** — revisit only if Miel later asks for bike-lock integration.

## 7. Open questions to resolve on first real Aura 150 connect

Log these explicitly and compare against this doc:
1. Does the Aura 150 identify as CFDL16-class in CLIENT_INFO, or something else entirely? (`sdkVersion`,
   `HUName`, `flavor` fields.)
2. Does `REQ_RV_CONFIG_CAPTURE` report `deviceWidth/Height` = 800×386, or a different resolution?
3. Does the raw frame-pull byte layout in §4 work as documented, or does the bike need something else
   (terminator, different length field size)?
4. Any unexpected cmd IDs on `:10922` not covered by §3 (would indicate a CFDL26-style extra step).

Everything else in this document is high-confidence; these four are the genuine unknowns until hardware
testing happens.
