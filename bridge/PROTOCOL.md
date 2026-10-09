# Plugchoice bridge protocol, version 1

The contract between the hosted page at `https://connect.plugchoice.com` and the native shells in this repository (`ios/`, `android/`). The page runs the flow (setting up a charger, today); the shell only does what a web page can't: join a device's Wi-Fi, find devices on the local network and talk HTTP, WebSocket, TCP and UDP to them, talk Bluetooth, scan a code with the camera, fetch the client secret from the host app, and close the screen with a result.

Design rules:

- **Generic tools in the shell, brands and flows in the page.** The shell knows no charger brand, device type or flow, so a new brand or flow ships as a page deploy, never as an SDK release. Where the platform forces a host-app declaration (iOS `NSBonjourServices`), the shell reports what is declared.
- **Our own calls, not browser-API polyfills.** No `navigator.bluetooth` emulation: the page has its own Web Bluetooth transport for browsers.
- **The page also runs without a shell** (plain browser). It detects the bridge and falls back to browser transports.
- **One origin.** Only `https://connect.plugchoice.com` (or a debug override, §2) may use the bridge, and every network call stays on the local network.

---

## 1. Versions and compatibility

The page at `connect.plugchoice.com` is always the newest version; apps ship whatever SDK version they have and update late. So:

- **The page supports every SDK version still in use.** It learns what the shell can do from `hello` (§5): `bridgeVersion` and `capabilities`. It only calls methods whose capability is listed.
- **The shell never handles older pages.** It implements the current version of this document, nothing before it.
- **A new method or behaviour gets a new capability.** Shells without it don't list it, and the page doesn't use it there. A new optional param is safe too: shells ignore params they don't know.
- **`bridgeVersion` increases only when an existing method's behaviour changes incompatibly.** The page then keeps the old behaviour for shells that answer the old version.

This document is version 1.

## 2. Opening the screen

The host app creates one SDK instance with a callback that fetches a **client secret** from the host's own server (which got it from `POST /sdk/v1/client-sessions`), and opens the screen with an **action**. The callback receives that action (`action`, `chargerId`, `siteId`), so the host's server can scope the secret to the charger or site being opened.

| Platform | Call |
|---|---|
| iOS | `Plugchoice(fetchClientSecret: (LinkAction) async throws -> String, options:)`, then `plugchoice.link.present(_ action: LinkAction, from:completion:)` (or the SwiftUI modifier `plugchoiceLink(isPresented:plugchoice:action:onCompletion:)`) |
| Android | `Plugchoice(fetchClientSecret = suspend (LinkAction) -> String)`, then `registerForActivityResult(plugchoice.link.contract())` and `launch(LinkAction)` |
| React Native | `configurePlugchoice({ fetchClientSecret: (action) => Promise<string> })`, then `openLink({ action, chargerId?, siteId? })` |

Before showing anything the shell:

1. Builds `https://connect.plugchoice.com/#action=<action>`, plus `&charger_id=<id>` and `&site_id=<id>` when given (and not empty), each value percent-encoded (everything but RFC 3986's unreserved characters). The action is an open string (`add`, `setup`, `reconnect`, or a later one) that the shell passes on without reading it. The URL never holds the secret.
2. Uses `https://connect.plugchoice.com` as the **only** allowed origin, for the bridge and for main-frame navigation (an explicit `:443` is the same origin).
3. **Debug override**: `options.hostOverride` (for example `http://192.168.1.20:5173`, a local copy of the page) replaces the scheme, host and port and becomes the only allowed origin. It must be `http` or `https`, a host and an optional port, with at most a trailing `/`. It is honoured only in debug builds of the host app (iOS: `#if DEBUG`, as the package builds from source with the app's configuration; Android: the app's `FLAG_DEBUGGABLE`), and otherwise ignored with a log line, as is a malformed one.
4. Calls the host's callback once with the action, in parallel with loading the page, and keeps the answer for the page's first `auth.clientSecret` (§7).

The screen shows the page full screen (iOS: a sheet that can't be swiped away), keeps the display awake (a device's hotspot drops when the phone locks), and keeps working when the page loses internet after loading (the phone is on the device's hotspot for part of the flow). It shows a native close button until the page answers `hello` (§5).

- **Navigation**: the main frame stays on the allowed origin. A link the user taps to anywhere else opens in another app (`http`, `https`, `mailto`, `tel`); any other navigation off the origin is dropped. Subframes load, but can't use the bridge.
- **A new document** in the main frame (a reload or navigation) cancels everything the previous one started (requests, sockets, sessions, browses, scans, Bluetooth connections) without answers or events, and brings the native close button back until the new document's `hello`.
- **Load failure**: when the main frame doesn't load (no internet, server unreachable), the shell shows a native error screen with **Try again** (loads the URL again) and the native close button, which closes at once with `error` / `pageLoadFailed`.

## 3. Transport

**Page → native.** The page serialises each message to a JSON **string** and posts it:

| Platform | How the page posts | How the shell receives |
|---|---|---|
| iOS | `window.webkit.messageHandlers.plugchoiceLink.postMessage(json)` | `WKScriptMessageHandler` named `plugchoiceLink` |
| Android | `window.plugchoiceLinkAndroid.postMessage(json)` | `WebViewCompat.addWebMessageListener(webView, "plugchoiceLinkAndroid", allowedOriginRules, listener)` (androidx.webkit) |

The page detects the runtime by checking which of the two objects exists. Neither: browser mode.

**Native → page.** The shell calls, on the main thread, `window.PlugchoiceLinkBridge.receive("<json string>")` (iOS `evaluateJavaScript`, Android `evaluateJavascript`), with the JSON embedded as a JS string literal by a JSON encoder (never escaped by hand). The page defines `window.PlugchoiceLinkBridge` before it sends `hello`, so the shell never queues.

**Origin check.** The shell takes messages only from the main frame of the allowed origin (iOS: `frameInfo.isMainFrame` and `securityOrigin`; Android: `allowedOriginRules` and `isMainFrame`), and delivers answers and events only while the main frame is on it. Everything else is dropped silently.

## 4. Messages

```jsonc
// request (page → native)
{ "type": "request", "id": "r12", "method": "wifi.join", "params": { /* … */ } }

// response (native → page), exactly one per request
{ "type": "response", "id": "r12", "ok": true,  "result": { /* … */ } }
{ "type": "response", "id": "r12", "ok": false, "error": { "code": "userDenied", "message": "…", "details": { /* optional */ } } }

// event (native → page), unsolicited
{ "type": "event", "event": "ws.message", "params": { /* … */ } }
```

- A message that isn't a JSON string holding an object is dropped, and so is a request without a string `id` (there is nobody to answer). `id` is chosen by the page and unique per page load.
- `params` and `result` are objects (`{}` when empty; absent or `null` params read as `{}`). Params a method doesn't know are ignored.
- `error.code` is a camelCase code (§13); `message` is free text for logs; `details` is an optional object (a `tls` error's `presentedFingerprint`).
- Any method can answer `unsupportedMethod` (unknown method), `invalidParams` (a param missing, of the wrong type or out of range) and `internal`.

Conventions for every method:

- **Strings** that are required are non-empty, except `wifi.join`'s `password`, `ws.send`'s `data` and base64 values.
- **`timeoutMs`**: any positive number, rounded up to whole milliseconds and capped at 2³¹−1. Some are clamped to a range (§12).
- **Bytes** travel as standard base64; `=` padding is optional, whitespace and the base64url alphabet are not allowed.
- **`headers`** (`Record<string, string>`, optional): names are RFC 9110 tokens, values visible ASCII, spaces and tabs.

## 5. Handshake: `hello`

The page sends `hello` first and waits for the answer before anything else.

| Params | Result |
|---|---|
| `{}` | `{ bridgeVersion: 1, sdkVersion: string, platform: "ios" \| "android", osVersion: string, capabilities: string[], lanServiceTypes: string[] \| null }` |

- `sdkVersion` is the SDK release, the same on iOS and Android.
- `lanServiceTypes`: the DNS-SD service types `lan.discover` can browse. iOS: the host's `NSBonjourServices`, without trailing dots. Android: `null`, meaning any type.
- Once it has answered, the shell hides its native close button (the page draws its own close control) and leaves closing to the page (§6.2).

| Capability | What works | Listed |
|---|---|---|
| `wifi.join` | `wifi.ensurePermissions`, `wifi.join`, `wifi.leave`, `wifi.currentSsid`, `wifi.routeTraffic` (§8) | Always |
| `wifi.accessory` | `wifi.join` goes through AccessorySetupKit | iOS 18+ with `WiFi` in the host's `NSAccessorySetupKitSupports` |
| `http.request` | `http.request`, `http.cancel` (§9.2) | Always |
| `ws` | `ws.open`, `ws.send`, `ws.close` and the `ws.*` events (§9.3) | Always |
| `session.close` | `session.close` (§6.1) | Always |
| `camera.scanCode` | `camera.scanCode` (§10) | iOS: the host has `NSCameraUsageDescription` and the device a camera. Android: always |
| `ui.closeRequest` | the `ui.closeRequested` event and `ui.closeHandled` (§6.2) | Always |
| `lan.address` | `lan.address` (§9.4) | Always |
| `lan.discover` | `lan.discover`, `lan.stopDiscovery` (§9.4) | iOS: the host declares at least one `NSBonjourServices` type. Android: always |
| `http.session` | `http.session.open`, `.request`, `.close` (§9.5) | Always |
| `auth.clientSecret` | `auth.clientSecret` (§7) | Always |
| `ble` | `ble.*` (§11) | The device has Bluetooth LE, and iOS: the host has `NSBluetoothAlwaysUsageDescription`; Android: the host kept the library's Bluetooth permissions |
| `tcp` | `tcp.open`, `tcp.write`, `tcp.close` (§9.6) | Always |
| `udp` | `udp.exchange` (§9.7) | Always |
| `trust.custom` | trust objects (§9.8) | Always |

## 6. Closing

### 6.1 `session.close`

The flow is over. The shell answers `{}`, dismisses the screen and hands the result to the host app.

| Params | Result |
|---|---|
| `{ status: "success" \| "cancelled" \| "error", action?: string, sessionId?: string, devices?: { type: string, id: string }[], error?: { code: string, message?: string } }` | `{}` |

- `action`: the action the run did; absent or empty, the one the screen opened with.
- `sessionId`: the run; empty is none.
- `devices`: the devices the run finished (on `success`), passed on for any status; absent is none. `type` is an open string (`charger` today) and a host ignores types it doesn't know. `type` and `id` are non-empty.
- `error`: why it ended with `error`; `code` is non-empty.

The host gets `LinkResult { status, action, sessionId, devices, error }`. It is a convenience for the app's UI: the host's server confirms with `GET /sdk/v1/link-sessions/{id}`.

### 6.2 Native closes: `ui.closeRequested`, `ui.closeHandled`

Leaving in the middle of a run can leave a device half set up (during a reboot, for example), so after `hello` the page decides when the screen closes. When the user tries to leave natively (iOS: swiping the sheet down; Android: back), the shell stays open and sends:

```jsonc
{ "type": "event", "event": "ui.closeRequested", "params": {} }
```

Within **1 s** the page calls `session.close`, or `ui.closeHandled` (`{}` → `{}`) to say it is alive and asking the user (for example "Stop setting up?"). If neither arrives in time (a hung page), the shell closes with `cancelled`. Trying again while the shell waits doesn't extend the deadline. Before `hello` (while loading, on the load-error screen) a native close closes at once.

### 6.3 The shell's own results

When the shell closes by itself, it reports the action it opened with, no `sessionId` and no devices:

| Result | When |
|---|---|
| `cancelled` | The user left before `hello`, a hung page let 1 s pass (§6.2), or the host app closed the screen |
| `error` / `pageLoadFailed` | The user left the load-error screen (§2) |
| `error` / `internal` | The shell couldn't run the page (Android: no usable WebView, or its renderer died) |

`clientSecretUnavailable` is the page's to report (§7), never the shell's.

## 7. `auth.clientSecret`

| Params | Result | Errors |
|---|---|---|
| `{}` | `{ clientSecret: string }` | `clientSecretUnavailable` |

- The first call answers with the secret fetched when the screen opened (§2), waiting for that fetch if needed. Every later call runs the host's callback again, with the same action; the page calls it when its secret has expired.
- `clientSecretUnavailable`: the callback threw, returned an empty (or blank) string, or took longer than 30 s. The page shows its error screen with **Try again**, which calls `auth.clientSecret` again.
- The shell never logs the secret and keeps no copy after answering.

## 8. Wi-Fi

### `wifi.ensurePermissions`

| Params | Result | Errors |
|---|---|---|
| `{}` | `{}` | `locationPermissionDenied`, `locationServicesOff` |

Asks for what a join needs, before the system's join sheet. Android: `NEARBY_WIFI_DEVICES` (API 33+), or precise location and location services on (API 32 and lower). iOS: when-in-use location if never asked (to read the SSID); never fails.

### `wifi.join`

Joins a device's own access point (no internet behind it). **Resolves only once the phone is on `ssid`.**

| Params | Result |
|---|---|
| `{ ssid: string, password: string, timeoutMs: number, displayName?: string, productImageUrl?: string }` | `{ via: "accessory" \| "configuration" \| "specifier", pickerShown: boolean, silentRejoin: boolean }` |

- `ssid`: 1 to 32 bytes of UTF-8. An empty `password` joins an open network.
- **iOS with `wifi.accessory`**: AccessorySetupKit. If no accessory with this SSID is paired yet, the picker shows (`displayName`, else the SSID, and the image from `productImageUrl`, else a generic symbol); then `joinAccessoryHotspot`. `silentRejoin: true`: later joins need no prompt.
- **iOS otherwise**: a `joinOnce` `NEHotspotConfiguration` (the system "Join network?" sheet every time); "already associated" counts as success. `silentRejoin: false`.
- **Android**: a `WifiNetworkSpecifier` (WPA2) in a network request with `TRANSPORT_WIFI` and **without** `NET_CAPABILITY_INTERNET`. The request stays registered, holding the connection, until `wifi.leave` or the screen closes. `silentRejoin: true` (the OS remembers the approval per app and SSID).
- Already on `ssid`: answers at once with `pickerShown: false` (Android: see §15).
- **`timeoutMs` covers getting onto the network, not the user's time in system UI.** iOS starts the clock when the system's join call returns, then checks the current SSID about once a second. Android runs its own timeout and stops it while the screen lacks window focus (the approval dialog), capping the whole join at `timeoutMs` + 110 s. The page gives the call `timeoutMs` + 120 s before giving up on the answer.

Errors: `userDenied` (the picker or join sheet was cancelled), `invalidPassphrase`, `didNotFindNetwork`, `unableToConnect` (association failed, or on another network afterwards), `timeoutOccurred`, `locationPermissionDenied` and `locationServicesOff` (Android), `unavailableForOSVersion`. Which of these a platform can tell apart: §15.

### `wifi.leave`, `wifi.currentSsid`, `wifi.routeTraffic`

| Method | Params | Result | Errors |
|---|---|---|---|
| `wifi.leave` | `{ ssid: string }` | `{}` | never fails |
| `wifi.currentSsid` | `{}` | `{ ssid: string \| null }` (`null` when unknown) | |
| `wifi.routeTraffic` | `{ enabled: boolean }` | `{}` | `unableToConnect` (Android: enabled without a joined network) |

- `wifi.leave` forgets the device's network, so the phone returns to its normal Wi-Fi, and turns `wifi.routeTraffic` off.
- `wifi.routeTraffic`: whether local-network calls (§9) started from now on go over the joined device network. The shell **never** binds the whole process to it: the host app and the web view keep their internet. Android binds each call's sockets to the joined network; iOS routes the hotspot's subnet over Wi-Fi by itself and keeps such calls off cellular.

## 9. Local network

### 9.1 Rules for every call

**Host rules.** `http.request`, `ws.open`, `http.session.open`, `tcp.open` and `udp.exchange` reach only:

- IPv4 literals in 10/8, 172.16/12, 192.168/16, 169.254/16 (link-local) and 127/8 (loopback), as strict dotted quads (no leading zeros, no shorthand such as `10.1` or `167772161`);
- `::1` (with or without brackets) and `localhost`;
- `*.local` names of letters, digits, `-`, `_` and dots (a trailing dot is fine).

Anything else, a percent-encoded host, and for URLs another scheme answer `forbiddenHost`; a URL that doesn't parse or isn't absolute is `invalidParams`. Params are checked before the host: a bad param is `invalidParams` even for a forbidden host. Without these rules the bridge would be an open, CORS-free proxy for any page that got loaded.

- **Routing** follows `wifi.routeTraffic` (§8) as it is when the call starts; a session or socket keeps that route for its whole life. Android with routing on but the joined network gone: `network`.
- **Local Network permission** (iOS): when it is missing, `lan.discover` (§9.4), `http.session.open`, `tcp.open` and `udp.exchange` answer `localNetworkDenied` at once rather than at `timeoutMs`; `http.request` and `ws.open` fail as the system reports it (`network` or `timeout`). iOS can't tell a prompt still showing from a denial, so a call made while the prompt shows is refused too; the page tries again once the user has answered (a `lan.discover` first puts the prompt up before any sweep).
- **HTTP**: no proxy, no cookie jar (a page's `Cookie` header goes out verbatim), redirects not followed (the 3xx comes back), response header names lower-cased with repeated headers joined by `", "`, bodies UTF-8 text.
- **TLS**: the system's trust, or a trust object (§9.8).

### 9.2 `http.request`, `http.cancel`

| Method | Params | Result |
|---|---|---|
| `http.request` | `{ requestId: string, url: string, method: "GET" \| "POST" \| "PUT" \| "PATCH" \| "DELETE", headers?, body?: string, timeoutMs: number, trust?: Trust, responseBody?: "text" \| "base64" }` | `{ status: number, headers: Record<string, string>, body: string }` |
| `http.cancel` | `{ requestId: string }` | `{}`; the request then answers `cancelled` (an unknown id is fine) |

- `url` is `http` or `https`; `trust` applies to `https` only. `method` is case-insensitive.
- `responseBody` (absent: `text`): `text` answers the body decoded as UTF-8, so bytes that aren't UTF-8 are replaced; `base64` answers it as base64 of its bytes, for a binary body such as an archive. Anything else is `invalidParams`.
- `timeoutMs` is a deadline for the whole request.
- A `GET` can't have a body (an empty one is none). A `requestId` already in flight is `invalidParams`.

Errors: `forbiddenHost`, `invalidParams`, `tls`, `network`, `timeout`, `cancelled`.

### 9.3 `ws.open`, `ws.send`, `ws.close`

| Method | Params | Result |
|---|---|---|
| `ws.open` | `{ socketId: string, url: string, headers?, trust?: Trust }` | `{}` once the attempt started; the outcome arrives as events |
| `ws.send` | `{ socketId: string, data: string }` | `{}` |
| `ws.close` | `{ socketId: string }` | `{}` |

| Event | Params |
|---|---|
| `ws.open` | `{ socketId }` |
| `ws.message` | `{ socketId, data: string }` (text frames; binary frames are dropped) |
| `ws.error` | `{ socketId, message: string, code?: "tls", details?: { presentedFingerprint } }` |
| `ws.close` | `{ socketId, code: number, reason: string }`, always the last event for a socket |

- `url` is `ws` or `wss`; `trust` applies to `wss` only. Custom headers are sent (a device can require a session `Cookie`).
- `ws.close` answers `{}`, then the final `ws.close` event follows at once: code 1000, or 1006 for a socket still connecting (as a browser reports closing one). An unknown id is fine.
- A socket that fails or is dropped emits `ws.error`, then `ws.close` (1006 when there was no close frame).
- A `socketId` in use, or `ws.send` on an unknown one, is `invalidParams`; a failed send is `network`.

### 9.4 `lan.discover`, `lan.stopDiscovery`, `lan.address`

| Method | Params | Result |
|---|---|---|
| `lan.discover` | `{ types: string[], timeoutMs: number, stopOnName?: string }` | `{ services: { name: string, addresses: string[], port: number, txt: Record<string, string> }[] }` |
| `lan.stopDiscovery` | `{}` | `{}` |
| `lan.address` | `{}` | `{ ip: string \| null, netmask: string \| null }` |

`lan.discover` browses DNS-SD (mDNS) on the network the phone is on and resolves each instance it finds.

- `types`: DNS-SD service types such as `_http._tcp` (`_name._tcp` or `_name._udp`, subtype labels allowed, a trailing dot optional; `invalidParams` otherwise). iOS browses only types the host declares (`hello`'s `lanServiceTypes`) and answers `undeclaredServiceType` for others; Android browses any.
- It answers with everything found when `timeoutMs` has passed, or as soon as an instance whose lower-cased name contains the lower-cased `stopOnName` (empty: none) has resolved to an IPv4 address.
- `addresses`: IPv4 first, IPv6 without a scope. An instance found but not resolved has `addresses: []` and `port: 0`.
- One browse at a time (`busy`). `lan.stopDiscovery` ends a running browse, which then answers with what it found (the two answers come in no fixed order).
- iOS shows the Local Network prompt on the first browse. `localNetworkDenied` when nothing was found and the browse was still waiting for the permission at the end (an unanswered prompt counts; the browse resumes if the user allows in time). `network` when none of the types could be browsed.

`lan.address`: the phone's IPv4 address and netmask on Wi-Fi, both `null` off Wi-Fi. The page uses it to sweep the subnet (with `http.session.open` or `tcp.open` probes, which need no declaration) when mDNS finds nothing.

Errors: `invalidParams`, `undeclaredServiceType`, `busy`, `localNetworkDenied`, `network`.

### 9.5 `http.session.open`, `http.session.request`, `http.session.close`

A kept-alive HTTPS connection to one device, for devices that keep their login on the TCP connection rather than in a cookie.

| Method | Params | Result |
|---|---|---|
| `http.session.open` | `{ host: string, port?: number, trust?: Trust, timeoutMs?: number }` | `{ sessionId: string }` |
| `http.session.request` | `{ sessionId: string, method: "GET" \| "POST" \| "PUT", path: string, headers?, body?: string, timeoutMs: number, responseBody?: "text" \| "base64" }` | `{ status: number, headers: Record<string, string>, body: string }` |
| `http.session.close` | `{ sessionId: string }` | `{}` |

- `open` makes the TCP and TLS handshake: `port` defaults to 443; `timeoutMs` defaults to 10 s and is clamped to 500 ms to 30 s (a subnet sweep probes with a short one). A refused or unreachable host fails with `network` as soon as the OS says so.
- **One connection per session**, never shared, pooled or silently replaced. Requests on a session run one at a time, in the order sent.
- A request's `timeoutMs` counts from when the shell receives it, so waiting behind earlier requests counts. A request that times out before it was sent leaves the session alone; once sent, `timeout` ends the session (the device may still answer, out of step). `network` ends it too. A request on an ended session answers `unknownSession`. When the device ends the connection after an answer (`Connection: close`, or a body that runs until the connection closes), that answer comes through and the next request answers `network`.
- `path` starts with `/` and holds printable ASCII without spaces or `#` (a query is fine). The body is sent with an explicit `Content-Length`, never chunked; a `GET` can't have one. The shell writes `Host` and `Content-Length` itself and drops the page's `Host`, `Content-Length`, `Transfer-Encoding` and `Connection`.
- `responseBody` as for `http.request` (§9.2).
- `close` is idempotent; requests still waiting answer `network`.
- At most 64 sessions, opening ones included (`tooManySessions`).
- `tls` only when the certificate didn't verify; any other failed handshake (plain HTTP on that port, for example) is `network`.

Errors: `forbiddenHost`, `invalidParams`, `unknownSession`, `tooManySessions`, `tls`, `localNetworkDenied`, `network`, `timeout`.

### 9.6 `tcp.open`, `tcp.write`, `tcp.close`

| Method | Params | Result |
|---|---|---|
| `tcp.open` | `{ socketId: string, host: string, port: number, timeoutMs?: number, tls?: { trust?: Trust, serverName?: string } }` | `{}` once connected (and the TLS handshake done) |
| `tcp.write` | `{ socketId: string, data: string }` | `{}` once handed to the OS |
| `tcp.close` | `{ socketId: string }` | `{}` |

Events: `tcp.data { socketId, data }` and `tcp.close { socketId, error?: string }` (`error` when the connection failed rather than ended), always the last event for a socket that opened. A socket that never opened has no events.

- `timeoutMs` as `http.session.open`. `tls` without `trust`: the system's trust. `serverName` is sent as SNI and matched against the certificate instead of the host.
- `tcp.close` on a socket still opening makes its `open` answer `network`; on an open socket the final `tcp.close` follows.
- At most 16 sockets, opening ones included (`tooManySockets`). A `socketId` in use is `invalidParams`; `tcp.write` on a socket that isn't open is `unknownSocket`.

Errors: `forbiddenHost`, `invalidParams`, `unknownSocket`, `tooManySockets`, `localNetworkDenied`, `tls`, `network`, `timeout`.

### 9.7 `udp.exchange`

| Params | Result |
|---|---|
| `{ host: string, port: number, data: string, timeoutMs: number, maxReplies?: number }` | `{ replies: { from: string, port: number, data: string }[] }` |

- Sends one datagram (at most 65 507 bytes) and collects replies until `maxReplies` (1 to 1000, default 1) have arrived or `timeoutMs` (clamped to 100 ms to 30 s) has passed.
- Replies come only from the address and port the datagram went to. Nothing listening there is no error: no replies at `timeoutMs`. A failure after replies came answers with those replies.
- **Unicast only**: multicast (224.0.0.0/4), 240.0.0.0/4 and 255.255.255.255 are `forbiddenHost`. Sending broadcast or multicast on iOS needs Apple's multicast entitlement in every host app, so the protocol leaves it out; a subnet's directed broadcast fails with `network`.

Errors: `forbiddenHost`, `invalidParams`, `localNetworkDenied`, `network`.

### 9.8 Trust objects

Where a page talks TLS to a device, it can say what to trust:

```ts
type Trust = {
  anchors?: string[];        // CA certificates, one PEM certificate per entry: the only anchors
  fingerprints?: string[];   // "sha256/<base64>" of a SubjectPublicKeyInfo: a leaf with one of these keys
  ignoreExpiry?: boolean;    // don't check the leaf's validity dates
  ignoreHostname?: boolean;  // don't match the leaf's names against the host
};
```

- Taken by `http.request` and `ws.open` (for `https` and `wss`), `http.session.open`, and `tcp.open` (`tls.trust`). Without one, the system's trust (with the host name checked).
- At least one of `anchors` and `fingerprints` (`invalidParams` otherwise). Text around a PEM's BEGIN and END lines is ignored; fingerprint padding is optional.
- A certificate is trusted when its leaf's key is in `fingerprints`, or when its chain (with what the device sends) verifies against `anchors` (signatures and CA constraints, not the extra rules for public web servers such as at most 825 days of validity). **Either way**, unless `ignoreExpiry` the leaf must be valid now, and unless `ignoreHostname` it must name the host in its subject alternative names (DNS names with at most one `*.` label, IP addresses; no common-name fallback). With `ignoreExpiry` an anchored chain is checked as of a moment inside the leaf's validity, so only the leaf's dates are forgiven.
- A device whose maker signs with a private CA and lets the leaves expire: `{ anchors: [makerCa], ignoreExpiry: true, ignoreHostname: true }`. There is no "accept anything", and the host rules (§9.1) still apply, so a page-supplied anchor never touches the open internet.
- A refused certificate is a `tls` error with `details.presentedFingerprint`, the presented leaf's fingerprint (also on `ws.error`).

## 10. `camera.scanCode`

| Params | Result | Errors |
|---|---|---|
| `{ formats: ["qr"], title?: string, hint?: string }` | `{ value: string, format: "qr" }` (the first code found) | `userCancelled`, `cameraPermissionDenied`, `unavailable` |

- A native full-screen scanner over the page, for a device's setup QR code. A scan already showing is `unavailable`.
- iOS: `AVCaptureSession` with a QR metadata output, on every supported device. The host needs `NSCameraUsageDescription`; without it the capability isn't listed and the call answers `unavailable`.
- Android: the Google code scanner (Play services), which needs no camera permission and draws its own UI. Without Play services (or when its module can't be downloaded) the call answers `unavailable`.
- **The page keeps a typed fallback**: a listed `camera.scanCode` can still answer `unavailable`.
- `value` can hold secrets (a setup code can carry the hotspot password): shells never log it.

## 11. Bluetooth (`ble`)

Bluetooth LE as a GATT client. The page decides what to look for and what to write.

| Method | Params | Result |
|---|---|---|
| `ble.ensurePermissions` | `{}` | `{}` |
| `ble.scan` | `{ services?: string[], timeoutMs: number, stopOnName?: string }` | `{ devices: BleDevice[] }` |
| `ble.stopScan` | `{}` | `{}` |
| `ble.connect` | `{ deviceId: string, timeoutMs: number, mtu?: number }` | `{ mtu: number, maxWriteLength: number, services: { uuid: string, characteristics: { uuid: string, properties: string[] }[] }[] }` |
| `ble.read` | `{ deviceId, service, characteristic }` | `{ value: string }` |
| `ble.write` | `{ deviceId, service, characteristic, value: string, withResponse: boolean }` | `{}` |
| `ble.subscribe` | `{ deviceId, service, characteristic }` | `{}` |
| `ble.unsubscribe` | `{ deviceId, service, characteristic }` | `{}` |
| `ble.disconnect` | `{ deviceId }` | `{}` |

```ts
type BleDevice = {
  deviceId: string;               // opaque: iOS the peripheral's identifier, Android the address
  name: string | null;            // the advertised local name, else the cached name
  rssi: number;
  serviceUuids: string[];         // advertised
  manufacturerData: { companyId: number; data: string }[];  // `data` without the 2-byte company id
  serviceData: { uuid: string; data: string }[];
  connectable: boolean | null;    // null when the platform doesn't say
};
```

| Event | Params |
|---|---|
| `ble.notification` | `{ deviceId, service, characteristic, value }` (notifications and indications) |
| `ble.disconnected` | `{ deviceId, reason: "requested" \| "remote" \| "timeout" \| "error", message?: string }`, always the last event for a connection |

- **Bytes** travel as base64 (`value`, `data`). **UUIDs** are answered as full 128-bit lower-case strings; params take the full form or a 16- or 32-bit short form (`a002`, `0000a002`).
- **Permissions**: `ble.ensurePermissions` asks for what Bluetooth needs and checks it is on. Every other method but `ble.stopScan` and `ble.disconnect` makes the same checks first (and may prompt), so a page can skip it. iOS creates its central manager on the first such call, never at `hello`, which shows the system prompt the first time; it waits for the user's answer. Android 12+: `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`; Android 10 and 11: precise location, and location services on to scan.
- **`ble.scan`** uses `services` as the OS scan filter (absent or empty: every device). It answers at `timeoutMs` (clamped to 1 s to 60 s), or as soon as a device whose lower-cased name contains the lower-cased `stopOnName` (empty: none) shows up, with every device seen so far, once each (latest RSSI and name, advertised data added up). One scan at a time (`busy`); `ble.stopScan` ends it, and it answers with what it found.
- **`ble.connect`** needs a `deviceId` from a scan on this page (`unknownDevice` otherwise). It connects and discovers every service and characteristic within `timeoutMs` (clamped to 1 s to 60 s); Android also requests `mtu` (23 to 517, default 247). A device already connected answers its current state; one still connecting answers `busy`. `maxWriteLength` is the longest write without response.
- **Characteristic `properties`**: any of `read`, `write`, `writeWithoutResponse`, `notify`, `indicate`. A request on a characteristic without the property needed is `notPermitted`; one the device doesn't have is `unknownCharacteristic`.
- **`ble.write`**: at most 512 bytes; a write with response longer than the MTU allows goes as a long write. Without response, `value` must fit `maxWriteLength` (`invalidParams`).
- **`ble.subscribe`** enables notifications, or indications when the characteristic has only those; it answers once the device confirmed. Values then arrive as `ble.notification`.
- **Order and timeouts**: requests on one device run one at a time, in the order sent, each with a 10 s operation timeout. A request that times out answers `timeout` and ends the connection (`ble.disconnected` with `timeout`): the device may still answer, out of step.
- **Pairing**: when a characteristic needs it, the OS asks the user on access. There is no `ble.bond`.
- **`ble.disconnect`** is idempotent: a connected device answers `{}`, then `ble.disconnected` with `requested`; one still connecting makes its `ble.connect` answer `notConnected`.
- At most 8 connections, connecting ones included (`tooManyConnections`). Everything ends with the page or the screen, without events.

Errors: `bluetoothOff`, `bluetoothPermissionDenied`, `locationServicesOff` (Android 10 and 11, scanning), `unavailable` (no Bluetooth LE, or the host didn't declare it), `busy`, `unknownDevice`, `notConnected`, `unknownCharacteristic`, `notPermitted`, `tooManyConnections`, `timeout`, `gatt` (the device refused; `message` carries the status).

Not AccessorySetupKit: declaring it for Bluetooth limits CoreBluetooth in the whole host app to accessories set up through it, and needs every brand's services in the host's Info.plist.

## 12. Limits and timeouts

| What | Value |
|---|---|
| `timeoutMs` | Positive, rounded up to whole milliseconds, at most 2³¹−1 |
| Answer to `ui.closeRequested` | 1 s |
| Host app's `fetchClientSecret` | 30 s |
| `wifi.join` | `timeoutMs`; Android caps the whole join at `timeoutMs` + 110 s |
| `http.request` | `timeoutMs` for the whole request |
| `http.session.open`, `tcp.open` | `timeoutMs` 10 s when absent, clamped to 500 ms to 30 s |
| `http.session.request` | `timeoutMs` from when the shell receives it; response headers up to 64 KiB, body up to 16 MiB (`network` beyond) |
| `udp.exchange` | `timeoutMs` clamped to 100 ms to 30 s; `maxReplies` 1 to 1000; a datagram up to 65 507 bytes |
| `ble.scan`, `ble.connect` | `timeoutMs` clamped to 1 s to 60 s |
| Bluetooth request | 10 s; `ble.write` up to 512 bytes; `mtu` 23 to 517 |
| At once | 1 `lan.discover`, 1 `ble.scan`, 1 `camera.scanCode`; 64 sessions, 16 TCP sockets, 8 Bluetooth connections |

## 13. Error codes

| Code | Where |
|---|---|
| `unsupportedMethod`, `invalidParams`, `internal` | Any method |
| `userDenied`, `invalidPassphrase`, `didNotFindNetwork`, `unableToConnect`, `timeoutOccurred`, `unavailableForOSVersion` | `wifi.join` (`unableToConnect` also `wifi.routeTraffic`) |
| `locationPermissionDenied`, `locationServicesOff` | `wifi.ensurePermissions`, `wifi.join`; `locationServicesOff` also `ble.*` |
| `clientSecretUnavailable` | `auth.clientSecret` |
| `forbiddenHost` | `http.request`, `ws.open`, `http.session.open`, `tcp.open`, `udp.exchange` |
| `network`, `timeout`, `tls`, `cancelled` | Local-network calls; `cancelled` only `http.request` |
| `localNetworkDenied` | `lan.discover`, `http.session.open`, `tcp.open`, `udp.exchange` (iOS) |
| `undeclaredServiceType`, `busy` | `lan.discover` (`undeclaredServiceType` iOS); `busy` also `ble.scan`, `ble.connect` |
| `unknownSession`, `tooManySessions` | `http.session.*` |
| `unknownSocket`, `tooManySockets` | `tcp.*` |
| `userCancelled`, `cameraPermissionDenied`, `unavailable` | `camera.scanCode`; `unavailable` also `ble.*` |
| `bluetoothOff`, `bluetoothPermissionDenied`, `unknownDevice`, `notConnected`, `unknownCharacteristic`, `notPermitted`, `tooManyConnections`, `gatt` | `ble.*` |

`LinkResult.error` codes the shell sets itself: `pageLoadFailed` and `internal` (§6.3). Every other code comes from the page.

## 14. What the host app needs

| Platform | Needs |
|---|---|
| iOS | `NSLocalNetworkUsageDescription`, and `NSAllowsLocalNetworking` under `NSAppTransportSecurity` for plain HTTP to devices; `NSBonjourServices` with every type the page browses; `NSLocationWhenInUseUsageDescription` (reading the SSID); `NSCameraUsageDescription` (scanning); `NSBluetoothAlwaysUsageDescription` (Bluetooth; App Store Connect asks for it anyway, since the SDK links CoreBluetooth); `WiFi` in `NSAccessorySetupKitSupports` for `wifi.accessory`; the Hotspot Configuration and Access Wi-Fi Information entitlements. The React Native config plugin adds all of them, with `_alfen._tcp`, `_http._tcp` and `_https._tcp` plus the app's own types as `NSBonjourServices`. |
| Android | Nothing to add: the library's manifest merges `INTERNET`, the network and Wi-Fi state permissions, `CHANGE_WIFI_MULTICAST_STATE`, location up to API 32, `NEARBY_WIFI_DEVICES`, `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_CONNECT`, and `BLUETOOTH` and `BLUETOOTH_ADMIN` up to API 30. Removing the Bluetooth ones turns `ble` off. minSdk 29. |

## 15. Platform notes

What each shell does where the platforms differ. The page must cope with all of it.

| Topic | iOS | Android |
|---|---|---|
| New document | When the main frame commits it. | When the main frame starts loading it. |
| Web content process dies | Reloads the page. | Closes with `error` / `internal` (the WebView can't be reused). |
| Native close button | Top right of the sheet, until `hello`. | Floating top right (40 dp), until `hello`. |
| `wifi.join` failure codes | The full set: AccessorySetupKit and `NEHotspotConfiguration` say why. A malformed SSID or configuration from the OS answers `invalidParams`. | The OS doesn't say why: `timeoutOccurred` when the shell's timeout runs out, `unableToConnect` otherwise; never `userDenied` or `didNotFindNetwork`. `invalidPassphrase` only when the OS refuses the passphrase up front. |
| `wifi.join` success | Polls the current SSID after the system call. | The network becoming available means "on that SSID"; no polling (it would need location on API 33+). |
| `pickerShown` | True when the accessory picker showed. | A guess: true when the screen lost focus during the join (the approval dialog). |
| Already on the SSID | Whenever the current SSID is `ssid`. | Only while this screen's earlier join of `ssid` holds the network; otherwise it requests the network again. |
| `wifi.ensurePermissions` | Asks for when-in-use location if never asked; always `{}`. | Precise and approximate location (API 31 and 32), precise location (29 and 30) or Nearby Wi-Fi devices (33+). |
| `wifi.join` without permission | Needs none. | `locationPermissionDenied` until `wifi.ensurePermissions` got it. |
| `wifi.leave` | Removes the configuration for `ssid`. | Drops the one network it joined, whatever `ssid` says. |
| `wifi.currentSsid` | `NEHotspotNetwork.fetchCurrent` (needs location permission, or a network the app configured). | The SSID it joined while that network is up, else the system's (needs location permission). |
| `wifi.routeTraffic` | Never fails; calls started while it is on stay off cellular. | Binds sockets to the joined network; `unableToConnect` without one. `ws.open` when that network is gone answers `{}`, then `ws.error` and `ws.close` 1006. |
| Host names | Resolved by the system (`*.local` by mDNS). | Must resolve to a local address (the IPv4 ranges of §9.1, IPv6 loopback, link-local or unique-local), else `network`. |
| `localNetworkDenied`, `undeclaredServiceType` | Answered where §9 says. | Never answered (no Local Network permission, no declarations). |
| `lan.discover` | `NWBrowser` browses; `NetService` resolves without connecting to the device. | `NsdManager` with a multicast lock held while browsing; before API 34 one resolve at a time. |
| `lan.address` | The Wi-Fi interface (`en0`). | The default network when it is Wi-Fi, else another Wi-Fi network, the joined one last. |
| `camera.scanCode` | Shows `title` and `hint`. A QR code without text is skipped. | Doesn't show `title` and `hint`. A QR code without text answers `internal`. |
| `ble` listed | Never in the simulator (no radio). | On Android 12+ only when the host targets API 31 or later. |
| `ble.*` without permission | Without `NSBluetoothAlwaysUsageDescription` every method answers `unavailable` and CoreBluetooth is never touched. | Location services are checked only for `ble.scan` and `ble.ensurePermissions`, and only on API 29 and 30. |
| `ble.scan` | `connectable` may be `null`. | `connectable` is never `null`. Android throttles an app that starts more than five scans in 30 s (no results, no error): scan once per attempt. |
| `ble.connect` `mtu` | Ignored: iOS negotiates by itself; the answer's `mtu` is `maxWriteLength` + 3. | Requested. Android 14 and later negotiate 517 by themselves. |
| `ble.disconnected` `reason` (unrequested) | `remote`, `timeout` or `error` from CoreBluetooth's error. | From the GATT status: 0 or the peer disconnecting → `remote`, 8 → `timeout`, anything else → `error` with `message: "status N"`. |
| Bluetooth turned off | A running scan answers with what it found, a connecting device answers `bluetoothOff`, a connected one emits `ble.disconnected` with `error`. | Connected devices emit `ble.disconnected` as the OS drops them; a running scan runs out its time. |
| Pairing | — | A slow answer to the system's pairing prompt can run into the 10 s request timeout, which ends the connection. |
| Weak linking | AccessorySetupKit is weak-linked, so the SDK runs on iOS 16 and 17. | — |
