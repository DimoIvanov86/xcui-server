# xcui-server

An HTTP server that runs inside an XCUITest on a real iPhone and drives any installed app.

The UI test `testResidentServer` starts a small HTTP server on port 8200 and never returns, so the
test runner stays alive. A client forwards the port over USB and sends requests: launch an app by bundle
id, find elements, tap, type, scroll, take screenshots and answer permission alerts. It is similar to
WebDriverAgent, but smaller and without Appium.

## Requirements

- Xcode (the project was created with Xcode 26; deployment target iOS 16)
- An iPhone with Developer Mode on (Settings > Privacy & Security) and Enable UI Automation on
  (Settings > Developer)
- An Apple development team. `DEVELOPMENT_TEAM` is empty in the project: set it on both targets in
  Xcode, or pass `DEVELOPMENT_TEAM=<team id>` to xcodebuild. Change the `com.example.*` bundle ids if
  your team needs its own.
- `iproxy` from libimobiledevice (`brew install libimobiledevice`)

## Build

```sh
xcodebuild build-for-testing \
  -project XCUIServer.xcodeproj -scheme XCUIServer \
  -destination id=<udid> -derivedDataPath build
```

`idevice_id -l` lists the UDIDs of connected phones.

## Run

```sh
xcodebuild test-without-building \
  -project XCUIServer.xcodeproj -scheme XCUIServer \
  -destination id=<udid> -derivedDataPath build \
  -only-testing:XCUIServerUITests/XCUIServerUITests/testResidentServer
```

The command keeps running while the server is up. Wait for this line in its output:

```
XCUI_SERVER_READY port=8200 phase=1
```

Then forward the port from another terminal and try it:

```sh
iproxy 8200 8200 -u <udid>
curl -s localhost:8200/status
curl -s -X POST localhost:8200/launch -d '{"bundleId": "com.apple.Preferences"}'
```

For several phones, forward each one to a different local port (`iproxy 8201 8200 -u <udid2>`).

## Configuration

`XCUI_MAIN_TIMEOUT` (default 25) is how many seconds a request may hold the main thread before it is
answered with a timeout. It must be between 5 and 60; any other value is logged and 25 is used. Test-runner environment variables need the `TEST_RUNNER_` prefix:

```sh
TEST_RUNNER_XCUI_MAIN_TIMEOUT=40 xcodebuild test-without-building ...
```

The server shuts itself down when nobody uses it. After 2 minutes without a request it terminates the
app it launched; after 4 minutes it also exits. Any request resets the timer, so a client that pauses on
purpose should poll `/status`.

## How requests behave

- Bodies are JSON. Element queries match `identifier`, `label` or `value`, case-insensitive: exact
  matches first, then substring matches.
- `type` filters by element type: `button`, `staticText` (or `text`), `cell`, `textField`,
  `secureTextField`, `textView`, `searchField`, `image`, `switch`, `toggle`, `slider`, `link`, `picker`,
  `pickerWheel`, `segmentedControl`, `table`, `collectionView`, `scrollView`, `navigationBar`, `tabBar`,
  `toolbar`, `alert`, `sheet`, `menuItem`, `keyboard`, `key`, `webView`, `other`. Responses report
  `elementType` with the same names; types not in the list come back as `other`.
- Until the first `/launch`, routes that act on the app return `{"ok": false, "error": "NO_APP"}`.
  Requests that read SpringBoard (`scope: "springboard"`) or another bundle (`target`) work before that.
- XCUITest work runs on the main thread with a time limit. A request that runs out of time gets
  `{"ok": false, "error": "timeout"}`. XCTest calls can't be cancelled, so the work keeps going; until it
  finishes (plus 8 seconds) other requests get `{"ok": false, "error": "busy"}` and `/status` reports
  `"mainBusy": true`. `/launch` and `/terminate` skip the 8-second cool-down and are refused only
  while the earlier call is still running.
- If the app crashes during a request the answer is `{"ok": false, "crashed": true, "exception": "..."}`
  and the server keeps running.
- Most routes accept a pending permission alert first (see below).
- An unknown path gets HTTP 404 with `{"ok": false, "error": "no route: ..."}`.

## Routes

Points are in the app's coordinate space. `nx`/`ny` values are fractions (0 to 1) of the app frame.

| Route | Body | Response |
|-------|------|----------|
| `GET /status` | | `ready`, `server: "xcui-server"`, `api`, `mainTimeout` (seconds), `unexpectedAlert`, `mainBusy`, `thermal` |
| `POST /launch` | `bundleId`, optional `language` (default `en`), `locale` | `{"ok": true, "language"}`. Always switches to `bundleId`. Without it, relaunches the current app. |
| `POST /terminate` | | `{"ok": true}` |
| `POST /mediaPlayPause` | | `{"ok": true}`. Presses the hardware Play/Pause key. |
| `POST /tap` | `ptX`/`ptY`, or `nx`/`ny`, or `query` with optional `type`, `index`, `withLabel`, `container`, `contains`, `target`, `scope`, `timeout` (default 8), `live`, `dryRun` | See below. |
| `POST /tapAnchored` | `anchor`, optional `targetType` (default `button`) | `ok`, `x`, `y`, `id`. Taps the control on the same row as the anchor text. |
| `POST /revealAndTap` | `query`, optional `revealNx`, `revealNy`, `maxPolls`, `settleMs`, `targetX`, `targetY` | `ok`, `x`, `y`, `id` (or `mode: "coord"` with `targetX`/`targetY`). For a control on a bar that hides itself: shows the bar and taps in one call. |
| `POST /type` | `text`, optional `query`, `type`, `index`, `container`, `timeout` (default 8), `focused`, `target`, `scope` | `ok`, `attempts`, `elementType`, `placeholder`, `id`, `value` (or `secure`, `maskLen`). Clears the field, types and reads it back, up to 3 tries. With `focused`, types into the focused field: `ok`, `focused`, `typed`. |
| `POST /find` | `query`, optional `type`, `index`, `container`, `contains`, `withLabel`, `timeout` (default 1), `hittable`, `field`, `target`, `scope` | See below. |
| `POST /describe` | optional `max` (40), `maxPerId` (6), `includeCells`, `includeText`, `target`, `scope` | `{"ok": true, "count", "elements": [{type, id, label, value, selected, enabled, x, y, w, h}]}` |
| `POST /scroll` | optional `direction`: `up` (default), `down`, `left`, `right`, the way the finger moves | `{"ok": true}` |
| `POST /scrollTo` | `query`, optional `maxSteps` (12), `step` (0.3), `center`, `noLoadWait`, `goingDown`, `reversed` | `ok`, `steps`, `y` or `centered`. When time runs out: `NOT_REACHED` with `deadline: true`, `seen`, `goingDown`, `reversed`; send `goingDown`, `reversed` and `noLoadWait: true` back to continue. |
| `POST /probe` | `queries` (list of strings), optional `scope` (`app` or `springboard`), `target` | `{"ok": true, "present": [...]}` |
| `POST /permission` | optional `button`, `wait` (seconds, default 2) | `ok`, `button`, `unexpectedAlert` |
| `POST /setPicker` | `values`, one per wheel, left to right | `ok`, `wheels`, `turned` |
| `POST /drag` | `nx1`, `ny1`, `nx2`, `ny2`, optional `duration` (0.6) | `{"ok": true}` |
| `POST /back` | optional `buttonOnly` | `ok`, `mode` (`button` or `swipe`) |
| `GET /screenshot` | | PNG image |

`/tap` answers `ok`, `x`, `y`, `id`, `elementType`, `label`, `value`, `selected`, plus:

- `mode`: `coord` for a coordinate tap (with `space: "points"` for `ptX`/`ptY`), `lean` for the fast path
  plain queries take; absent on the full path
- `clamped: true` when only the visible part of a partly off-screen control was tapped
- `returnKey: true` when the query was a return-key label (`return`, `done`, `search`, ...) that matched
  nothing and the keyboard's return key was pressed instead
- `dryRun: true` when `dryRun` was sent: the answer describes the tap without touching anything, on every
  path (coordinates, query, return key). `keyboardClose: true` says the keyboard would be closed first.
- on a timeout, the element's details when the touch had already been made

`/find` answers `found`, `determinate`, `hittable`, `elementType`, `label`, `value`, `selected`, `id`,
`x`, `y`, `w`, `h`. `determinate: true` means the answer is reliable either way; a timeout or busy reply
means the screen couldn't be read. With `hittable: false` the hit test is skipped (some overlays dismiss
themselves on it) and `hittable` comes back `null`. If the request also has no `container`, `contains`,
`index`, `withLabel` or `field`, it takes a faster path that adds `mode: "presence"`. `field: true` finds the field
the way `/type` would and adds `field: true` to a miss.

### Touch routes: `tapped` and `TOO_LATE`

`/tap`, `/tapAnchored`, `/revealAndTap`, `/type`, `/scroll`, `/scrollTo`, `/drag`, `/setPicker`,
`/back`, `/permission` and `/mediaPlayPause` touch the screen (or press a key). Every answer from these
routes, errors and `timeout` included, has two flags:

- `tapped`: whether any touch was made.
- `done`: whether the route's own action was started: the target tap, the gesture of `/scroll`,
  `/scrollTo`, `/drag` and `/back`, the last wheel of `/setPicker`, the last character of `/type`.
  `/type` clears and retypes up to three times, and `done` describes only the latest attempt: it means
  that attempt typed the whole text (each new attempt first clears the field, so `done` goes back to
  false until its last character).

Some routes touch something first to prepare their action: `/revealAndTap` shows the bar, `/tap` may close
the keyboard, `/setPicker` turns the earlier wheels, `/type` focuses and clears the field and types the
text before its last character. For routes with a single touch, `done` equals `tapped`.

| `tapped` | `done` | Meaning |
|----------|--------|---------|
| `false` | `false` | Nothing was touched and nothing will be. Safe to send again. |
| `true` | `false` | Only a preparatory touch was made (a reveal, a keyboard close, some of the wheels or the text). |
| `true` | `true` | The action was made, even if the answer is a `timeout`. Don't resend blindly. |

A successful answer can have `done: false` when there was nothing to do, for example `/setPicker` with
every wheel already on its value.

A request that runs out of time can keep running on the phone after it has been answered, so these
routes start no touch after a deadline just short of the time limit (`mainTimeout`, or the longer
`/type` limit). A touch that would start later is skipped and the request answers `TOO_LATE`. That is
why a `timeout` answer's `tapped` and `done` are final. A `timeout` without `tapped: false` (for example,
from an older server) may have touched.

Accepting a system permission alert before the action (see Permission alerts) doesn't count as a
touch: it doesn't change what resending the request would do.

### Errors

Errors come back as HTTP 200 with `{"ok": false, "error": "<CODE>"}` unless noted.

| Route | Codes |
|-------|-------|
| any | `NO_APP`, `timeout`, `busy`, `crashed: true` (with `exception`), `json_serialize_failed` (a response that could not be encoded) |
| touch routes | `TOO_LATE` (see above) |
| `/tap` | `NO_MATCH`, `NOT_FOUND`, `OFF_SCREEN`, `COVERED` (with `coveredBy` when it is the keyboard) |
| `/tapAnchored` | `NO_ANCHOR`, `ANCHOR_NOT_VISIBLE`, `NO_SNAPSHOT`, `ANCHOR_OR_TARGET_NOT_FOUND`, `OFF_SCREEN` |
| `/revealAndTap` | `TARGET_NOT_ON_HUD` |
| `/type` | `NO_FIELD`, `NOT_FOCUSED`, `FIELD_GONE`, `TYPE_DEADLINE`, `TYPE_MISMATCH` (with `value`, `expected`), `SECURE_LEN_MISMATCH` (with `maskLen`, `expectedLen`) |
| `/scrollTo` | `NO_QUERY` (HTTP 400), `END_OF_LIST`, `NOT_REACHED` |
| `/setPicker` | `NO_PICKER` |
| `/drag` | `BAD_COORDS` (HTTP 400) |
| `/back` | `NO_NAV_BACK` (only with `buttonOnly`) |
| `/mediaPlayPause` | a sentence saying why the key event could not be sent |

`target` (a bundle id) and `scope: "springboard"` read another process's UI, such as a system sheet.
`/permission`, `/screenshot` and `/mediaPlayPause` work before any `/launch`, as do `/tap`, `/find`,
`/type`, `/describe` and `/probe` when they read SpringBoard or another bundle.

## Permission alerts

The server accepts a system alert only if its text asks for one of these: microphone, camera, location,
notifications, tracking or photos. It then taps the first button it finds from `Allow While Using App`,
`Allow`, `OK`, `Allow Once`, `Continue` or `Use Camera`.

Every other alert is left on screen and its text is reported as `unexpectedAlert` by `/status` and
`/permission`. An alert such as an iOS update prompt has an OK button as well, and accepting it blindly
could change the phone.

## Private API

XCTest normally waits for the app to go idle before every tap or swipe, and an app that never stops
animating (for example, one playing a video) blocks every action until that wait times out. The server
switches this wait off the same way WebDriverAgent does, by replacing private XCTest methods at runtime
(`QuiescenceDisable.m`). `/mediaPlayPause` also uses a private XCTest class (`MediaKey.m`). A future Xcode
release could break either one. On startup the server logs which methods it replaced.

## Project layout

```
XCUIServer/           empty host app
XCUIServerUITests/
  XCUIServerUITests.swift    HTTP server and routes
  ExceptionCatcher.h/.m      catches Objective-C exceptions
  QuiescenceDisable.h/.m     turns off XCTest's idle wait
  MediaKey.h/.m              sends hardware key events
```
