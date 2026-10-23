//
//  XCUIServerUITests.swift
//
//  A resident XCUITest command server. testResidentServer() never returns: it starts a small
//  HTTP server on port 8200 and parks the run loop, so the runner stays alive and drives
//  whichever app the last /launch named.
//
//  Every XCUIElement call runs on the main thread via runOnMainBounded().
//

import XCTest

// MARK: - Tunables

let serverPort: UInt16 = 8200
let httpRecvTimeoutSec: Int = 30
let bindMaxAttempts = 15                    // a dying previous instance can hold the port for a while
let bindRetryDelaySec: TimeInterval = 2
let maxRecycledCellScan = 12                // resolve(): cap on the off-screen copy scan
let firstMatchTimeoutSec: TimeInterval = 4

/// How long a request may hold the main thread before it is answered "timeout": XCUI_MAIN_TIMEOUT
/// seconds when it is between 5 and 60, else 25.
let mainTimeout: Double = {
    guard let raw = ProcessInfo.processInfo.environment["XCUI_MAIN_TIMEOUT"], !raw.isEmpty else { return 25 }
    if let seconds = Double(raw), seconds.isFinite, seconds >= 5, seconds <= 60 {
        return seconds
    }
    NSLog("XCUI ignoring XCUI_MAIN_TIMEOUT=\(raw): it must be 5 to 60 seconds; using 25")
    return 25
}()

/// After an overrun ends, new work is still refused this long: a stalled app recovers faster if it
/// is left alone for a few seconds.
let busyCoolDownSec: TimeInterval = 8

/// Bumped when a route or parameter the client relies on is added.
let serverApi = 2

// MARK: - HTTP server

/// Minimal HTTP/1.1 server on POSIX sockets. One thread per connection, so a request that holds
/// the main thread does not stop /status from answering.
final class TinyHTTPServer {
    typealias Handler = (_ body: String) -> (Int, String, Data)

    private let port: UInt16
    private var routes: [String: Handler] = [:]   // key = "GET /status"
    private var listenFD: Int32 = -1
    private let workers = DispatchQueue(label: "xcui.http.workers", attributes: .concurrent)
    init(port: UInt16) { self.port = port }
    func route(_ key: String, _ handler: @escaping Handler) { routes[key] = handler }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw err("socket() failed") }
        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0   // INADDR_ANY
        var bound = false
        for attempt in 0..<bindMaxAttempts {
            let bindRes = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if bindRes == 0 {
                bound = true
                break
            }
            NSLog("XCUI bind() attempt \(attempt) failed errno=\(errno), retrying in \(Int(bindRetryDelaySec))s")
            Thread.sleep(forTimeInterval: bindRetryDelaySec)
        }
        guard bound else { throw err("bind() failed after retries errno=\(errno)") }
        guard listen(listenFD, 16) == 0 else { throw err("listen() failed errno=\(errno)") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { continue }
            lastRequestAt.set(Date())
            workers.async { [weak self] in
                var tv = timeval(tv_sec: httpRecvTimeoutSec, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                self?.handle(client)
                close(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if let r = data.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(data: data.subdata(in: data.startIndex..<r.lowerBound), encoding: .utf8) ?? ""
                let cl = contentLength(headers)
                if data.distance(from: r.upperBound, to: data.endIndex) >= cl { break }
            }
        }
        let request = String(data: data, encoding: .utf8) ?? ""
        let req = parseRequest(request)
        let (status, ctype, bodyData) =
            routes["\(req.method) \(req.path)"]?(req.body)
            ?? (404, "application/json", Data("{\"ok\":false,\"error\":\"no route: \(req.method) \(req.path)\"}".utf8))
        respond(fd, status: status, contentType: ctype, body: bodyData)
    }

    private func contentLength(_ headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func parseRequest(_ request: String) -> (method: String, path: String, body: String) {
        let head: String, body: String
        if let blankLine = request.range(of: "\r\n\r\n") {
            head = String(request[..<blankLine.lowerBound])
            body = String(request[blankLine.upperBound...])
        } else {
            head = request
            body = ""
        }
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let tokens = requestLine.components(separatedBy: " ")
        let method = tokens.first ?? ""
        var path = tokens.count > 1 ? tokens[1] : "/"
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])   // no route takes query parameters
        }
        return (method, path, body)
    }

    private func respond(_ fd: Int32, status: Int, contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        out.withUnsafeBytes { raw in _ = write(fd, raw.baseAddress, raw.count) }
    }
    private func err(_ m: String) -> NSError { NSError(domain: "TinyHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
}

// MARK: - JSON helpers

func jsonResp(_ obj: [String: Any], _ status: Int = 200) -> (Int, String, Data) {
    // JSONSerialization raises an NSException on NaN/Infinity, which try? does not catch.
    var d = Data("{}".utf8)
    let ex = XSRunCatchingNSException {
        if let j = try? JSONSerialization.data(withJSONObject: obj) { d = j }
    }
    if ex != nil { d = Data("{\"ok\":false,\"error\":\"json_serialize_failed\"}".utf8) }
    return (status, "application/json", d)
}
/// Off-screen elements can report NaN/Infinity frames; send 0 instead.
func jnum(_ d: CGFloat) -> Double { d.isFinite ? Double(d) : 0 }
func parseJSON(_ s: String) -> [String: Any] {
    guard let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// MARK: - Main-thread execution

final class LockedValue<T> {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { value = initial }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
}

/// Tracks main-thread blocks that ran past their timeout. XCTest queries can't be cancelled, so
/// anything queued behind an overrun would overrun too; new work is refused as busy instead.
final class MainOverrunTracker {
    final class Call {
        var done = false
        var overran = false
    }
    private let lock = NSLock()
    private var count = 0
    private var limit: Double = 0
    private var coolUntil = Date.distantPast
    var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 || Date() < coolUntil }
    /// Ignores the cool-down, so /launch and /terminate are not refused needlessly.
    var isOverrunning: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    /// The time limit of the call that overran most recently.
    var overrunLimit: Double { lock.lock(); defer { lock.unlock() }; return limit }
    func markOverrun(_ c: Call, limit: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if c.done { return false }
        c.overran = true
        count += 1
        self.limit = limit
        return true
    }
    func markDone(_ c: Call) {
        lock.lock(); defer { lock.unlock() }
        c.done = true
        if c.overran {
            count -= 1
            coolUntil = Date().addingTimeInterval(busyCoolDownSec)
        }
    }
}
let mainOverrun = MainOverrunTracker()

/// Runs `work` on the main thread, catching any NSException and giving up after `timeout`.
/// Returns the result and a fault string: "TIMED_OUT ..." (the block keeps running and its result
/// is discarded), "BUSY ..." (refused because an earlier block is still overrunning), or the
/// caught exception.
func runOnMainBounded<T>(_ fallback: T, timeout: Double = mainTimeout, ignoreCoolDown: Bool = false,
                         _ work: @escaping () -> T) -> (T, String?) {
    func run() -> (T, String?) {
        var r = fallback
        let ex = XSRunCatchingNSException { r = work() }
        return (r, ex.map { "\($0.name.rawValue): \($0.reason ?? "<no reason>")" })
    }
    if Thread.isMainThread { return run() }
    if ignoreCoolDown ? mainOverrun.isOverrunning : mainOverrun.isBusy {
        return (fallback, "BUSY: a previous query overran its \(Int(mainOverrun.overrunLimit))s bound; the main thread is still busy or cooling down")
    }
    let box = LockedValue<(T, String?)>((fallback, nil))
    let sem = DispatchSemaphore(value: 0)
    let call = MainOverrunTracker.Call()
    DispatchQueue.main.async {
        box.set(run())
        mainOverrun.markDone(call)
        sem.signal()
    }
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        _ = mainOverrun.markOverrun(call, limit: timeout)
        return (fallback, "TIMED_OUT after \(Int(timeout))s (main-thread query still running; screen too dense/dynamic)")
    }
    return box.get()
}

func thermalStateName() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
}

/// Timeout and busy faults are ordinary errors; any other fault is a caught exception and is
/// reported as `crashed: true`.
func faultResponse(_ fault: String, extra: [String: Any] = [:]) -> (Int, String, Data) {
    var body: [String: Any] = ["ok": false]
    if fault.hasPrefix("TIMED_OUT") {
        body["error"] = "timeout"; body["detail"] = fault
    } else if fault.hasPrefix("BUSY") {
        body["error"] = "busy"; body["detail"] = fault
    } else {
        body["crashed"] = true; body["exception"] = fault
    }
    for (k, v) in extra { body[k] = v }
    return jsonResp(body)
}

func respOr(_ fault: String?, _ ok: [String: Any]) -> (Int, String, Data) {
    if let f = fault { return faultResponse(f) }
    return jsonResp(ok)
}

/// For routes that touch the screen. runOnMainBounded can answer "timeout" while its block is still
/// running, so the block calls mayTouch() before every touch: no touch starts after `deadline`,
/// and every answer can say whether a touch was made (`tapped`) and whether the route's own action
/// was (`done`), as opposed to a preparatory touch such as showing a bar or closing the keyboard.
final class TouchGuard {
    let deadline: Date
    private let touchedValue = LockedValue(false)
    private let doneValue = LockedValue(false)

    init(deadline: Date) { self.deadline = deadline }

    /// Leaves room before the main-thread bound for the touch itself.
    convenience init() { self.init(deadline: Date().addingTimeInterval(0.85 * mainTimeout)) }

    var touched: Bool { touchedValue.get() }
    var done: Bool { doneValue.get() }

    /// False once the deadline has passed; the caller must then answer TOO_LATE without touching.
    /// `final` marks the touch that is the route's own action.
    func mayTouch(final: Bool = false) -> Bool {
        if Date() >= deadline { return false }
        touchedValue.set(true)
        if final { doneValue.set(true) }
        return true
    }

    /// For a route that retries its action: a new attempt undoes the previous one (e.g. /type clears
    /// the field), so `done` must describe only the latest attempt. `tapped` stays cumulative.
    func startAttempt() {
        doneValue.set(false)
    }

    /// The route's answer with `tapped` and `done` added. Called after runOnMainBounded returns: by
    /// then the deadline has passed or the block has finished, so no new touch can start.
    func answer(_ fault: String?, _ result: [String: Any], extra: [String: Any] = [:]) -> (Int, String, Data) {
        var added = extra
        added["tapped"] = touched
        added["done"] = done
        if let f = fault { return faultResponse(f, extra: added) }
        return jsonResp(result.merging(added) { $1 })
    }
}

let tooLate: [String: Any] = ["ok": false, "error": "TOO_LATE"]

/// An answer from a touching route that refused before touching anything.
func untouched(_ obj: [String: Any], _ status: Int = 200) -> (Int, String, Data) {
    return jsonResp(obj.merging(["tapped": false, "done": false]) { $1 }, status)
}

// MARK: - Element lookup

func mapType(_ s: String) -> XCUIElement.ElementType {
    switch s.lowercased() {
    case "button": return .button
    case "statictext", "text": return .staticText
    case "cell": return .cell
    case "textfield": return .textField
    case "securetextfield": return .secureTextField
    case "textview": return .textView
    case "image": return .image
    case "switch": return .switch
    case "toggle": return .toggle
    case "searchfield": return .searchField
    case "slider": return .slider
    case "link": return .link
    case "picker": return .picker
    case "pickerwheel": return .pickerWheel
    case "segmentedcontrol": return .segmentedControl
    case "table": return .table
    case "collectionview": return .collectionView
    case "scrollview": return .scrollView
    case "navigationbar", "navbar": return .navigationBar
    case "tabbar": return .tabBar
    case "toolbar": return .toolbar
    case "alert": return .alert
    case "sheet": return .sheet
    case "menuitem": return .menuItem
    case "keyboard": return .keyboard
    case "key": return .key
    case "webview": return .webView
    case "other": return .other
    default: return .any
    }
}

func typeName(_ t: XCUIElement.ElementType) -> String {
    switch t {
    case .button: return "button"
    case .staticText: return "staticText"
    case .cell: return "cell"
    case .textField: return "textField"
    case .secureTextField: return "secureTextField"
    case .searchField: return "searchField"
    case .textView: return "textView"
    case .image: return "image"
    case .switch: return "switch"
    case .slider: return "slider"
    case .table: return "table"
    case .collectionView: return "collectionView"
    case .scrollView: return "scrollView"
    case .navigationBar: return "navigationBar"
    case .tabBar: return "tabBar"
    case .toolbar: return "toolbar"
    case .alert: return "alert"
    case .sheet: return "sheet"
    case .link: return "link"
    case .picker: return "picker"
    case .pickerWheel: return "pickerWheel"
    case .segmentedControl: return "segmentedControl"
    case .toggle: return "toggle"
    case .keyboard: return "keyboard"
    case .key: return "key"
    case .webView: return "webView"
    case .menuItem: return "menuItem"
    case .application: return "application"
    default: return "other"
    }
}

/// identifier, label or value equal to `v`, ignoring case.
func exactMatch(_ v: String) -> NSPredicate {
    NSPredicate(format: "identifier ==[c] %@ OR label ==[c] %@ OR value ==[c] %@", v, v, v)
}

/// identifier, label or value containing `v`, ignoring case.
func partialMatch(_ v: String) -> NSPredicate {
    NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@", v, v, v)
}

/// The element a request's `container` names: by identifier, else by label, since navigation
/// bars are addressed by their title.
func containerScope(_ app: XCUIApplication, _ cid: String) -> XCUIElement {
    let byId = app.descendants(matching: .any).matching(identifier: cid).firstMatch
    if byId.exists { return byId }
    return app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", cid)).firstMatch
}

func onScreenFrame(_ f: CGRect, within bounds: CGRect) -> Bool {
    return f.width > 1 && f.height > 1 && bounds.contains(CGPoint(x: f.midX, y: f.midY))
}

func onScreenFrame(_ f: CGRect, in app: XCUIApplication) -> Bool {
    return onScreenFrame(f, within: app.frame)
}

/// The part of a frame inside `bounds`, or nil when less than 8x8 pt of it is visible.
func visiblePart(_ f: CGRect, within bounds: CGRect) -> CGRect? {
    guard f.width > 1, f.height > 1, f.midX.isFinite, f.midY.isFinite else { return nil }
    let v = f.intersection(bounds)
    return (v.isNull || v.width < 8 || v.height < 8) ? nil : v
}

func visiblePart(_ f: CGRect, in app: XCUIApplication) -> CGRect? {
    return visiblePart(f, within: app.frame)
}

func tapCenter(_ app: XCUIApplication, _ f: CGRect) {
    // Tap through the app's coordinate space: an element's own frame can turn null mid-animation and raise.
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
}

/// A snapshot node in pre-order. `nodes[i+1..<end]` is its subtree; indexes from `end` on were drawn after it.
struct SnapNode {
    let s: XCUIElementSnapshot
    let end: Int
    let parent: Int
}

func flattenSnapshot(_ root: XCUIElementSnapshot) -> [SnapNode] {
    var out: [SnapNode] = []
    func walk(_ s: XCUIElementSnapshot, _ parent: Int) {
        let i = out.count
        out.append(SnapNode(s: s, end: i + 1, parent: parent))
        for c in s.children { walk(c, i) }
        out[i] = SnapNode(s: s, end: out.count, parent: parent)
    }
    walk(root, -1)
    return out
}

/// The part of a frame inside `bounds`. Unlike visiblePart, a small element that is fully on screen
/// counts even when it is under 8 pt.
func drawnPart(_ f: CGRect, within bounds: CGRect) -> CGRect? {
    guard f.width > 1, f.height > 1, f.midX.isFinite, f.midY.isFinite else { return nil }
    let v = f.intersection(bounds)
    return isBigEnough(v, of: f) ? v : nil
}

func isBigEnough(_ v: CGRect, of f: CGRect) -> Bool {
    return !v.isNull && v.width >= min(8, f.width) && v.height >= min(8, f.height)
}

func isList(_ t: XCUIElement.ElementType) -> Bool {
    return t == .table || t == .collectionView || t == .scrollView
}

/// The part of node `i` actually drawn. A row scrolled under a header still reports an on-screen
/// frame, but only the part inside its enclosing lists is visible.
func clippedFrame(_ nodes: [SnapNode], _ i: Int, bounds: CGRect) -> CGRect? {
    guard var r = drawnPart(nodes[i].s.frame, within: bounds) else { return nil }
    var a = nodes[i].parent
    while a >= 0 {
        if isList(nodes[a].s.elementType) {
            r = r.intersection(nodes[a].s.frame)
            if !isBigEnough(r, of: nodes[i].s.frame) { return nil }
        }
        a = nodes[a].parent
    }
    return r
}

/// Index of the nearest list holding node `i`, or -1.
func enclosingList(_ nodes: [SnapNode], _ i: Int) -> Int {
    var a = nodes[i].parent
    while a >= 0 {
        if isList(nodes[a].s.elementType) { return a }
        a = nodes[a].parent
    }
    return -1
}

func isAncestor(_ nodes: [SnapNode], _ a: Int, of i: Int) -> Bool {
    return a < i && i < nodes[a].end
}

/// What lies on top of node `i` at `pt`: (1) a cell or button drawn later, outside the node's
/// subtree, or (2) chrome outside the node's list (a header button, nav bar, tab bar, toolbar or
/// keyboard). Rule 2 is needed because a header comes earlier in the tree than the list under it.
func coveringElement(_ nodes: [SnapNode], _ i: Int, at pt: CGPoint, bounds: CGRect) -> XCUIElementSnapshot? {
    let list = enclosingList(nodes, i)
    // A text field outside any list sits in a header, which is drawn above the list's rows.
    let headerField = list < 0 && [.searchField, .textField, .secureTextField].contains(nodes[i].s.elementType)
    var j = nodes[i].end
    while j < nodes.count {
        let o = nodes[j].s
        let isControl = o.elementType == .cell || o.elementType == .button
        if isControl, clippedFrame(nodes, j, bounds: bounds)?.contains(pt) == true,
           !(headerField && enclosingList(nodes, j) >= 0) {
            return o
        }
        j += 1
    }
    guard list >= 0 else { return nil }
    let chrome: Set<XCUIElement.ElementType> = [.button, .navigationBar, .tabBar, .toolbar, .keyboard, .searchField]
    for (k, n) in nodes.enumerated() where chrome.contains(n.s.elementType) {
        if isAncestor(nodes, list, of: k) || isAncestor(nodes, k, of: i) || k == i { continue }
        // Something that contains the whole list is a backdrop beneath it, not on top of it.
        if n.s.frame.contains(nodes[list].s.frame) { continue }
        if drawnPart(n.s.frame, within: bounds) != nil, n.s.frame.contains(pt) { return n.s }
    }
    return nil
}

func coverDescription(_ c: XCUIElementSnapshot?) -> String {
    guard let c = c else { return "" }
    let name = c.identifier.isEmpty ? c.label : c.identifier
    return String("\(typeName(c.elementType)):\(name)".prefix(60))
}

/// The tap target chosen from a single snapshot, which is far cheaper than live queries on dense
/// screens. Matching follows resolve(). For index 0 it prefers a copy that is visible and not
/// covered, since some screens draw the same control more than once.
struct SnapPick {
    let node: XCUIElementSnapshot?
    let rect: CGRect?          // visible part of the node; nil when every match is off screen
    let matches: Int
    let debug: [[String: Any]]
    var covered: Bool = false
    var coveredByKeyboard: Bool = false
}

func snapshotPick(_ nodes: [SnapNode], query v: String, type etype: XCUIElement.ElementType,
                  index: Int, withLabel: String?) -> SnapPick {
    // Use the snapshot's own bounds: app.frame is a live query, and the checks below run thousands of times.
    let bounds = nodes.first?.s.frame ?? .zero
    let lv = v.lowercased()
    var exact: [Int] = []
    var loose: [Int] = []
    for (i, n) in nodes.enumerated() where etype == .any || n.s.elementType == etype {
        let id = n.s.identifier.lowercased()
        let lab = n.s.label.lowercased()
        let va = ((n.s.value as? String) ?? "").lowercased()
        if id == lv || lab == lv || va == lv {
            exact.append(i)
        } else if exact.isEmpty && (id.contains(lv) || lab.contains(lv) || va.contains(lv)) {
            loose.append(i)
        }
    }
    var matches = exact.isEmpty ? loose : exact
    if let wl = withLabel?.lowercased(), !wl.isEmpty {
        let labelled = matches.filter { nodes[$0].s.identifier.lowercased() == lv && nodes[$0].s.label.lowercased() == wl }
        if !labelled.isEmpty { matches = labelled }
    }
    if matches.isEmpty { return SnapPick(node: nil, rect: nil, matches: 0, debug: []) }
    if index != 0 {
        guard index < matches.count else { return SnapPick(node: nil, rect: nil, matches: matches.count, debug: []) }
        let n = nodes[matches[index]].s
        return SnapPick(node: n, rect: clippedFrame(nodes, matches[index], bounds: bounds), matches: matches.count, debug: [])
    }
    // Preference: a visible, uncovered center; then an uncovered sliver past a screen edge;
    // then a covered center, which the caller scrolls into view instead of tapping.
    var debug: [[String: Any]] = []
    var centerCovered: (node: XCUIElementSnapshot, rect: CGRect, by: XCUIElementSnapshot?)? = nil
    var sliver: (XCUIElementSnapshot, CGRect)? = nil
    for i in matches {
        let n = nodes[i].s
        guard let vis = clippedFrame(nodes, i, bounds: bounds) else { continue }
        let center = CGPoint(x: n.frame.midX, y: n.frame.midY)
        let centerVisible = vis.contains(center)
        let pt = centerVisible ? center : CGPoint(x: vis.midX, y: vis.midY)
        let cov = coveringElement(nodes, i, at: pt, bounds: bounds)
        debug.append(["id": n.identifier, "label": String(n.label.prefix(40)), "x": jnum(pt.x), "y": jnum(pt.y),
                      "centerVisible": centerVisible, "coveredBy": coverDescription(cov)])
        if centerVisible && cov == nil { return SnapPick(node: n, rect: vis, matches: matches.count, debug: debug) }
        if centerVisible && centerCovered == nil { centerCovered = (n, vis, cov) }
        if !centerVisible && cov == nil && sliver == nil { sliver = (n, vis) }
        if debug.count >= 12 { break }
    }
    if let c = sliver { return SnapPick(node: c.0, rect: c.1, matches: matches.count, debug: debug) }
    if let c = centerCovered {
        return SnapPick(node: c.node, rect: c.rect, matches: matches.count, debug: debug, covered: true,
                        coveredByKeyboard: c.by?.elementType == .keyboard)
    }
    return SnapPick(node: nodes[matches[0]].s, rect: nil, matches: matches.count, debug: debug)
}

func tapResult(_ f: CGRect, _ id: String) -> [String: Any] {
    return ["ok": true, "x": jnum(f.midX), "y": jnum(f.midY), "id": id]
}

/// For /tapAnchored: the `type` element on the same row as the first static text containing
/// `anchor` (lowercased), searched in the nearest ancestor that holds both.
func anchoredTarget(root: XCUIElementSnapshot, anchor: String, type tt: XCUIElement.ElementType,
                    screen: CGRect) -> XCUIElementSnapshot? {
    func isAnchor(_ s: XCUIElementSnapshot) -> Bool {
        guard s.elementType == .staticText else { return false }
        if s.label.lowercased().contains(anchor) || s.identifier.lowercased().contains(anchor) { return true }
        return ((s.value as? String)?.lowercased().contains(anchor)) ?? false
    }
    func hasRealFrame(_ s: XCUIElementSnapshot) -> Bool {
        return s.frame.width > 1 && s.frame.height > 1
    }
    func firstTarget(_ node: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        for c in node.children {
            if c.elementType == tt && hasRealFrame(c) { return c }
            if let hit = firstTarget(c) { return hit }
        }
        return nil
    }
    func allTargets(_ node: XCUIElementSnapshot, _ out: inout [XCUIElementSnapshot]) {
        for c in node.children {
            if c.elementType == tt && hasRealFrame(c) { out.append(c) }
            allTargets(c, &out)
        }
    }
    // Tree order means nothing here (a section owns its header button and all its cards),
    // so pick the candidate closest to the anchor's row, preferring on-screen ones.
    func nearestOnRow(_ anc: XCUIElementSnapshot, toY y: CGFloat) -> XCUIElementSnapshot? {
        var all: [XCUIElementSnapshot] = []
        allTargets(anc, &all)
        let visible = all.filter { onScreenFrame($0.frame, within: screen) }
        return (visible.isEmpty ? all : visible).min { abs($0.frame.midY - y) < abs($1.frame.midY - y) }
    }
    var target: XCUIElementSnapshot?
    // Snapshots have no parent pointer, so carry the ancestors down.
    func walk(_ s: XCUIElementSnapshot, _ ancestors: [XCUIElementSnapshot]) {
        if target != nil { return }
        if isAnchor(s) {
            for anc in ancestors.reversed() {
                guard let t = firstTarget(anc) else { continue }
                target = nearestOnRow(anc, toY: s.frame.midY) ?? t
                return
            }
        }
        for c in s.children {
            walk(c, ancestors + [s])
            if target != nil { return }
        }
    }
    walk(root, [])
    return target
}

/// Finds an element by id, label or value (exact, then partial), optionally scoped to a
/// container and filtered by type. Uses firstMatch rather than materialising every match,
/// which can hang on dense screens.
func resolve(_ app: XCUIApplication, _ p: [String: Any], waitTimeout: TimeInterval = firstMatchTimeoutSec, deadline: Date? = nil) -> XCUIElement? {
    // `deadline` bounds the whole call; otherwise the wait is paid once per predicate.
    func budget() -> TimeInterval { max(0.2, min(waitTimeout, deadline?.timeIntervalSinceNow ?? waitTimeout)) }
    let value = (p["query"] as? String) ?? (p["label"] as? String) ?? (p["id"] as? String) ?? ""
    let index = p["index"] as? Int ?? 0
    let etype = mapType(p["type"] as? String ?? "any")
    let scope: XCUIElement
    if let cid = p["container"] as? String { scope = containerScope(app, cid) } else { scope = app }
    // No text: "the Nth element of this type in this container", for controls with neither id nor
    // label. Both type and container are required; a bare type matches the wrong control too easily.
    if value.isEmpty {
        let cid = (p["container"] as? String) ?? ""
        guard etype != .any, !cid.isEmpty else { return nil }
        let el = scope.descendants(matching: etype).element(boundBy: index)
        return el.waitForExistence(timeout: budget()) ? el : nil
    }
    func onScreen(_ el: XCUIElement) -> Bool { onScreenFrame(el.frame, in: app) }
    // contains=true: the cell whose subtree mentions `value`, i.e. "the card titled X".
    if (p["contains"] as? Bool) == true {
        let cells = scope.descendants(matching: .cell).containing(partialMatch(value))
        let el = index == 0 ? cells.firstMatch : cells.element(boundBy: index)
        return el.waitForExistence(timeout: budget()) ? el : nil
    }
    // withLabel tells apart controls that share an id.
    if let wl = p["withLabel"] as? String, !wl.isEmpty, index == 0 {
        let el = scope.descendants(matching: etype)
            .matching(NSPredicate(format: "identifier ==[c] %@ AND label ==[c] %@", value, wl)).firstMatch
        if el.waitForExistence(timeout: min(1.0, budget())) && onScreen(el) { return el }
    }
    for pred in [exactMatch(value), partialMatch(value)] {
        let q = scope.descendants(matching: etype).matching(pred)
        if index != 0 {
            let el = q.element(boundBy: index)
            if el.waitForExistence(timeout: budget()) { return el }
            continue
        }
        // Prefer an on-screen match: recycled list cells leave off-screen copies with the same id.
        let first = q.firstMatch
        if !first.waitForExistence(timeout: budget()) { continue }
        if onScreen(first) { return first }
        var onScreenAny: XCUIElement?
        for i in 0..<maxRecycledCellScan {
            let el = q.element(boundBy: i)
            if !el.exists { break }
            if onScreen(el) {
                if el.isHittable { return el }
                if onScreenAny == nil { onScreenAny = el }   // isHittable is sometimes wrong
            }
        }
        return onScreenAny ?? first
    }
    return nil
}

/// The lean tap's single live lookup: the `withLabel` match (short wait), then exact, then partial.
func liveFirstMatch(_ app: XCUIApplication, query: String, type etype: XCUIElement.ElementType, index: Int,
                    withLabel: String?, deadline: Date) -> XCUIElement? {
    var preds: [(NSPredicate, Bool)] = []          // (predicate, short wait)
    if let wl = withLabel, !wl.isEmpty {
        preds.append((NSPredicate(format: "identifier ==[c] %@ AND label ==[c] %@", query, wl), true))
    }
    preds.append((exactMatch(query), false))
    preds.append((partialMatch(query), false))
    for (pred, short) in preds {
        let q = app.descendants(matching: etype).matching(pred)
        let el = index == 0 ? q.firstMatch : q.element(boundBy: index)
        let budget = max(0.2, deadline.timeIntervalSinceNow)
        if el.waitForExistence(timeout: short ? min(1.0, budget) : budget) { return el }
    }
    return nil
}

/// Finds a text input by id, label, value or placeholder. With `strict`, a named field that
/// matches nothing returns nil so the caller can keep waiting; the final non-strict call falls
/// back to the only field of the right kind on screen.
func resolveField(_ app: XCUIApplication, _ p: [String: Any], strict: Bool = true) -> XCUIElement? {
    var value = (p["query"] as? String) ?? (p["label"] as? String) ?? (p["id"] as? String) ?? ""
    var wantedType = mapType(p["type"] as? String ?? "any")
    // A query that is a type name ("secureTextField") means "the first field of that type".
    let asType = mapType(value)
    if wantedType == .any, !value.isEmpty, [.textField, .secureTextField, .searchField, .textView].contains(asType) {
        wantedType = asType
        value = ""
    }
    let index = p["index"] as? Int ?? 0
    let scope: XCUIElement
    if let cid = p["container"] as? String { scope = containerScope(app, cid) } else { scope = app }
    // placeholderValue matters: a focused or filled field no longer exposes its placeholder as value.
    let preds: [NSPredicate] = value.isEmpty
        ? [NSPredicate(value: true)]
        : [NSPredicate(format: "identifier ==[c] %@ OR label ==[c] %@ OR value ==[c] %@ OR placeholderValue ==[c] %@", value, value, value, value),
           NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@ OR value CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", value, value, value, value)]
    let wanted = wantedType
    let sweep: [XCUIElement.ElementType] = wanted == .any
        ? [.searchField, .textField, .secureTextField, .textView] : [wanted]
    for etype in sweep {
        for pred in preds {
            let q = scope.descendants(matching: etype).matching(pred)
            let el = index == 0 ? q.firstMatch : q.element(boundBy: index)
            if el.exists { return el }
        }
    }
    if !value.isEmpty && strict { return nil }
    let q = value.lowercased()
    let passwordy = q.contains("pass") || q.contains("secure") || q.contains("pin")
    if !value.isEmpty {
        // Accept a named query only when exactly one field of the matching kind is on screen;
        // anything else is a guess that could type a password into the wrong field.
        if index != 0 { return nil }
        let kinds: [XCUIElement.ElementType] = wanted != .any ? [wanted]
            : (passwordy ? [.secureTextField] : [.textField, .searchField])
        var only: XCUIElement? = nil
        for etype in kinds {
            let q = scope.descendants(matching: etype)
            let n = q.count
            if n > 1 || (n == 1 && only != nil) { return nil }
            if n == 1 { only = q.element(boundBy: 0) }
        }
        return only
    }
    // Text views are left out: legal text is often a text view, and typing into it hangs.
    let order: [XCUIElement.ElementType] = passwordy
        ? [.secureTextField, .textField, .searchField]
        : [.textField, .searchField, .secureTextField]
    for etype in (wanted == .any ? order : [wanted]) {
        let el = scope.descendants(matching: etype).element(boundBy: index)
        if el.exists { return el }
    }
    return nil
}

// MARK: - System alerts and idle watchdog

/// An alert is accepted only if its text contains one of these. Matching on the buttons alone
/// would also accept things like an iOS update prompt.
let permissionAlertMarkers = [
    "access the microphone", "access the camera",
    "use your location", "your location while you use",
    "send you notifications",
    "track your activity",
    "access your photos", "select photos", "photo library",
]

let alertAcceptLabels = ["Allow While Using App", "Allow", "OK", "Allow Once", "Continue", "Use Camera"]

/// Text of the last system alert that was left alone; reported by /status and /permission.
let unexpectedAlert = LockedValue<String>("")

let lastRequestAt = LockedValue<Date>(Date())

// Idle limits. An idle server and an idle app both use device storage, so neither should be left
// running. The app goes first because relaunching it is cheap. Clients that pause on purpose
// (for example during a reinstall) should poll /status.
let idleExitMinutes: Double = 4
let appIdleTerminateMinutes: Double = 2

/// All text in an alert (title, message, buttons), lowercased.
func alertText(_ alert: XCUIElement) -> String {
    var text = alert.label.lowercased()
    if let snap = try? alert.snapshot() {
        func walk(_ s: XCUIElementSnapshot) {
            if !s.label.isEmpty { text += " " + s.label.lowercased() }
            for c in s.children { walk(c) }
        }
        walk(snap)
    }
    return text
}

/// Accepts pending permission alerts before an action. Must run on the main thread. Unrecognised
/// alerts are left up and recorded in `unexpectedAlert`.
func drainAlerts(_ springboard: XCUIApplication, _ maxRounds: Int = 3) {
    var n = 0
    while n < maxRounds {
        let alert = springboard.alerts.firstMatch
        if !alert.exists { return }
        let text = alertText(alert)
        guard permissionAlertMarkers.contains(where: { text.contains($0) }) else {
            unexpectedAlert.set(String(alert.label.prefix(200)))
            return
        }
        unexpectedAlert.set("")
        var tapped = false
        for l in alertAcceptLabels where alert.buttons[l].exists {
            alert.buttons[l].tap()
            tapped = true
            break
        }
        if !tapped { return }
        n += 1
    }
}

// MARK: - Resident server

final class XCUIServerUITests: XCTestCase {

    // Set by /launch. Read under the lock so a route can answer NO_APP up front; its methods are
    // only called on the main thread.
    private let appUnderTest = LockedValue<XCUIApplication?>(nil)
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func noApp(touching: Bool = false) -> (Int, String, Data) {
        var answer: [String: Any] = ["ok": false, "error": "NO_APP",
                                     "detail": "no app under test yet: POST /launch {\"bundleId\": \"...\"} first"]
        if touching {
            answer["tapped"] = false
            answer["done"] = false
        }
        return jsonResp(answer)
    }

    /// Whether the request reads SpringBoard (`scope: "springboard"`) or another bundle (`target`)
    /// instead of the app under test. Such requests work before any /launch.
    private func readsOtherProcess(_ p: [String: Any]) -> Bool {
        return (p["scope"] as? String) == "springboard" || !((p["target"] as? String) ?? "").isEmpty
    }

    /// The tree a request reads: SpringBoard, another bundle (e.g. for system sheets that live in
    /// another process), or the app under test, which is nil before the first /launch. Main thread
    /// only, because it may create an XCUIApplication.
    private func target(_ p: [String: Any]) -> XCUIApplication? {
        if (p["scope"] as? String) == "springboard" { return springboard }
        if let bid = p["target"] as? String, !bid.isEmpty { return XCUIApplication(bundleIdentifier: bid) }
        return appUnderTest.get()
    }

    // Swallow XCTest failures so a UI hiccup in a handler never ends the test, and with it the server.
    override func record(_ issue: XCTIssue) {
        NSLog("XCUI swallowed issue: \(issue.compactDescription)")
    }

    func testResidentServer() throws {
        continueAfterFailure = true
        // A screen that never stops animating would otherwise stall every event.
        NSLog("XCUI \(XSDisableQuiescenceWait())")
        let server = TinyHTTPServer(port: serverPort)
        registerRoutes(on: server)
        try server.start()
        NSLog("XCUI_SERVER_READY port=\(serverPort) phase=1")
        startIdleWatchdog()
        parkRunLoopForever()
    }

    private func registerRoutes(on server: TinyHTTPServer) {
        server.route("GET /status")      { _ in jsonResp(["ready": true, "server": "xcui-server",
                                                                  "api": serverApi,
                                                                  "mainTimeout": mainTimeout,
                                                                  "unexpectedAlert": unexpectedAlert.get(),
                                                                  "mainBusy": mainOverrun.isBusy,
                                                                  "thermal": thermalStateName()]) }
        server.route("POST /launch")     { body in self.handleLaunch(body) }
        server.route("POST /terminate")  { _ in self.handleTerminate() }
        server.route("POST /mediaPlayPause") { _ in self.handleMediaPlayPause() }
        server.route("POST /tap")        { body in self.handleTap(body) }
        server.route("POST /tapAnchored")  { body in self.handleAnchoredTap(body) }
        server.route("POST /revealAndTap") { body in self.handleRevealAndTap(body) }
        server.route("POST /type")       { body in self.handleType(body) }
        server.route("POST /find")       { body in self.handleFind(body) }
        server.route("POST /describe")   { body in self.handleDescribe(body) }
        server.route("POST /scroll")     { body in self.handleScroll(body) }
        server.route("POST /scrollTo")   { body in self.handleScrollTo(body) }
        server.route("POST /probe")      { body in self.handleProbe(body) }
        server.route("POST /permission") { body in self.handlePermission(body) }
        server.route("POST /setPicker")  { body in self.handleSetPicker(body) }
        server.route("POST /drag")       { body in self.handleDrag(body) }
        server.route("POST /back")       { body in self.handleBack(body) }
        server.route("GET /screenshot")  { _ in self.handleScreenshot() }
    }

    // Stage 1 terminates the app and keeps serving; stage 2 terminates the app and exits. Killing the
    // app here is the only cleanup that still happens if the host process dies without a teardown.
    private func startIdleWatchdog() {
        var appKilled = false
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            let idle = Date().timeIntervalSince(lastRequestAt.get())
            if idle < appIdleTerminateMinutes * 60 { appKilled = false }
            if !appKilled, idle >= appIdleTerminateMinutes * 60, idle < idleExitMinutes * 60 {
                NSLog("XCUI idle \(Int(idle / 60))min, terminating the app, still serving")
                if let app = self.appUnderTest.get() { _ = runOnMainBounded(()) { app.terminate() } }
                appKilled = true
            }
            if idle >= idleExitMinutes * 60 {
                NSLog("XCUI idle \(Int(idle / 60))min with no request, terminating the app, then exiting")
                if let app = self.appUnderTest.get() { _ = runOnMainBounded(()) { app.terminate() } }
                exit(0)
            }
        }
    }

    private func parkRunLoopForever() {
        // Without an input source run(mode:before:) returns at once and this loop spins the CPU.
        // A Mach port keeps the run loop blocked while it still drains the main queue.
        RunLoop.current.add(NSMachPort(), forMode: .default)
        while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    // MARK: Launch and terminate

    private func handleLaunch(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let bid = (p["bundleId"] as? String) ?? ""
        if bid.isEmpty && appUnderTest.get() == nil { return noApp() }
        let (_, fault) = runOnMainBounded((), ignoreCoolDown: true) {
            // Always re-point, even to the same bundle id; otherwise after driving another app
            // (e.g. Settings) every later query would read that app's tree.
            if !bid.isEmpty {
                self.appUnderTest.set(XCUIApplication(bundleIdentifier: bid))
            }
            guard let app = self.appUnderTest.get() else { return }
            // English unless the caller asks otherwise; these arguments affect only this app.
            let lang = (p["language"] as? String) ?? "en"
            let locale = (p["locale"] as? String) ?? (lang == "en" ? "en_US" : lang)
            app.launchArguments = ["-AppleLanguages", "(\(lang))", "-AppleLocale", locale]
            app.launch()
        }
        return respOr(fault, ["ok": true, "language": (p["language"] as? String) ?? "en"])
    }

    private func handleTerminate() -> (Int, String, Data) {
        guard let app = appUnderTest.get() else { return noApp() }
        let (_, f) = runOnMainBounded((), ignoreCoolDown: true) { app.terminate() }
        return respOr(f, ["ok": true])
    }

    // The hardware Play/Pause key (HID page 0x0C, usage 0xCD) toggles playback without touching the app's UI.
    private func handleMediaPlayPause() -> (Int, String, Data) {
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            guard g.mayTouch(final: true) else { return tooLate }
            if let why = XSPerformHIDEvent(0x0C, 0xCD, 0.1) { return ["ok": false, "error": why] }
            return ["ok": true]
        }
        return g.answer(fault, r)
    }

    // MARK: Tap

    private func handleTap(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let app = appUnderTest.get()
        if app == nil && !readsOtherProcess(p) { return noApp(touching: true) }
        let g = TouchGuard()
        if let answer = coordinateTap(app ?? springboard, p, g) { return answer }
        let timeout = p["timeout"] as? Double ?? 8
        // Deadlines start on the request thread because the main-thread bound is already running.
        let resolveDeadline = Date().addingTimeInterval(min(timeout, 0.6 * mainTimeout))
        // The element about to be tapped, so a timeout reply can name what was touched.
        let tappedElement = LockedValue<[String: Any]?>(nil)
        if canTapLean(p), let app = app {
            let (r, fault) = runOnMainBounded([String: Any]()) {
                self.leanTap(app, p, resolveDeadline: resolveDeadline, guard: g, tappedElement: tappedElement)
            }
            if fault != nil || r["fallback"] == nil { return tapAnswer(r, fault, g, tappedElement) }
        }
        let (r, fault) = runOnMainBounded([String: Any]()) {
            self.liveTap(app, p, timeout: timeout, resolveDeadline: resolveDeadline, guard: g, tappedElement: tappedElement)
        }
        return tapAnswer(r, fault, g, tappedElement)
    }

    /// Like TouchGuard.answer, plus the element's details on a timeout after the touch.
    private func tapAnswer(_ r: [String: Any], _ fault: String?, _ g: TouchGuard,
                           _ tappedElement: LockedValue<[String: Any]?>) -> (Int, String, Data) {
        var extra: [String: Any] = [:]
        if let f = fault, f.hasPrefix("TIMED_OUT"), let element = tappedElement.get() { extra = element }
        return g.answer(fault, r, extra: extra)
    }

    /// ptX/ptY in points (the space /describe and /find report) or nx/ny as fractions of the app
    /// frame. Nil when the request has neither. Before any /launch, `app` is SpringBoard.
    private func coordinateTap(_ app: XCUIApplication, _ p: [String: Any], _ g: TouchGuard) -> (Int, String, Data)? {
        let dryRun = (p["dryRun"] as? Bool) == true
        if let px = p["ptX"] as? Double, let py = p["ptY"] as? Double {
            let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
                let answer: [String: Any] = ["ok": true, "mode": "coord", "space": "points"]
                if dryRun { return answer.merging(["dryRun": true]) { $1 } }
                guard g.mayTouch(final: true) else { return tooLate }
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: px, dy: py)).tap()
                return answer
            }
            return g.answer(fault, r)
        }
        if let nx = p["nx"] as? Double, let ny = p["ny"] as? Double {
            let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
                let answer: [String: Any] = ["ok": true, "mode": "coord"]
                if dryRun { return answer.merging(["dryRun": true]) { $1 } }
                guard g.mayTouch(final: true) else { return tooLate }
                app.coordinate(withNormalizedOffset: CGVector(dx: nx, dy: ny)).tap()
                return answer
            }
            return g.answer(fault, r)
        }
        return nil
    }

    /// Plain queries take the lean path; a container, contains, another process or `live: true`
    /// takes the full one.
    private func canTapLean(_ p: [String: Any]) -> Bool {
        let query = (p["query"] as? String) ?? ""
        return !query.isEmpty && p["container"] == nil && (p["contains"] as? Bool) != true && p["target"] == nil
            && p["scope"] == nil && (p["live"] as? Bool) != true
    }

    /// One live first match, one snapshot of it, a coordinate tap and no reads afterwards. A
    /// whole-screen snapshot is taken only when the match is not hittable. Returns
    /// ["fallback": true] when nothing matched, so the full path can try. Main thread only.
    private func leanTap(_ app: XCUIApplication, _ p: [String: Any], resolveDeadline: Date, guard g: TouchGuard,
                         tappedElement: LockedValue<[String: Any]?>) -> [String: Any] {
        let query = (p["query"] as? String) ?? ""
        let etype = mapType(p["type"] as? String ?? "any")
        let index = p["index"] as? Int ?? 0
        let withLabel = p["withLabel"] as? String
        let dryRun = (p["dryRun"] as? Bool) == true
        drainAlerts(springboard)
        let bounds = app.frame
        guard let el = liveFirstMatch(app, query: query, type: etype, index: index, withLabel: withLabel, deadline: resolveDeadline),
              let snap = try? el.snapshot() else { return ["fallback": true] }
        let settled = settle(el, snap, bounds: bounds, until: resolveDeadline)
        var node = settled.node
        let f = settled.frame
        var rect: CGRect? = settled.hittable ? visiblePart(f, within: bounds) : nil
        var snapshotFound = false, picked = false   // picked: the node came from the snapshot
        if rect == nil && index == 0, let root = try? app.snapshot() {
            let pick = snapshotPick(flattenSnapshot(root), query: query, type: etype, index: 0, withLabel: withLabel)
            // Covered only by the keyboard: let keyboardCheck deal with it.
            if pick.covered && pick.coveredByKeyboard, let n = pick.node, let r = pick.rect {
                node = n
                rect = r
                picked = true
            } else if pick.covered, let n = pick.node {
                return ["ok": false, "error": "COVERED", "mode": "lean", "id": n.identifier, "label": n.label,
                        "x": jnum(n.frame.midX), "y": jnum(n.frame.midY)]
            }
            if let n = pick.node, let r = pick.rect {
                node = n
                rect = r
                picked = true
            }
            snapshotFound = pick.matches > 0
        }
        // If the snapshot found copies but all were clipped away, report OFF_SCREEN rather than
        // tapping whatever is on top of them.
        if rect == nil && !snapshotFound { rect = visiblePart(f, within: bounds) }
        guard var r = rect else {
            return ["ok": false, "error": "OFF_SCREEN", "mode": "lean", "x": jnum(node.frame.midX), "y": jnum(node.frame.midY)]
        }
        switch keyboardCheck(app, el, p, node: node, rect: r, picked: picked, guard: g) {
        case .answer(let answer): return answer
        case .clear(let n, let nr):
            node = n
            r = nr
        }
        var res: [String: Any] = tapResult(r, node.identifier)
        res["elementType"] = typeName(node.elementType)
        res["label"] = node.label
        res["value"] = (node.value as? String) ?? ""
        res["selected"] = node.isSelected
        res["mode"] = "lean"
        if dryRun {
            res["dryRun"] = true
            return res
        }
        guard g.mayTouch(final: true) else { return tooLate }
        tappedElement.set(["id": node.identifier, "label": node.label, "value": (node.value as? String) ?? "",
                           "selected": node.isSelected, "elementType": typeName(node.elementType)])
        tapCenter(app, r)
        return res
    }

    /// Whether the element can be tapped where it is. One still animating in gets up to a second
    /// to stop moving first. Returns its latest snapshot and frame.
    private func settle(_ el: XCUIElement, _ snap: XCUIElementSnapshot, bounds: CGRect, until deadline: Date)
        -> (node: XCUIElementSnapshot, frame: CGRect, hittable: Bool) {
        func tappable(_ f: CGRect) -> Bool {
            bounds.contains(CGPoint(x: f.midX, y: f.midY)) && visiblePart(f, within: bounds) != nil && el.isHittable
        }
        var node = snap
        var f = snap.frame
        if tappable(f) { return (node, f, true) }
        let settleEnd = min(Date().addingTimeInterval(1.0), deadline)
        var last = f
        while Date() < settleEnd {
            usleep(250_000)
            guard let s2 = try? el.snapshot() else { break }
            let moved = abs(s2.frame.midX - last.midX) + abs(s2.frame.midY - last.midY)
            last = s2.frame
            if moved < 1 {
                node = s2
                f = s2.frame
                break
            }
        }
        return (node, f, tappable(f))
    }

    private enum KeyboardCheck {
        case clear(XCUIElementSnapshot, CGRect)   // tap here
        case answer([String: Any])                // reply with this instead
    }

    /// The keyboard is another window, so a control beneath it still reads as hittable. Closes the
    /// keyboard when that can't submit anything (single-line field, return/done key) and returns the
    /// target's new place; otherwise answers COVERED.
    private func keyboardCheck(_ app: XCUIApplication, _ el: XCUIElement, _ p: [String: Any],
                               node: XCUIElementSnapshot, rect r: CGRect, picked: Bool, guard g: TouchGuard) -> KeyboardCheck {
        let kb = app.keyboards.firstMatch
        let isKey = node.elementType == .key || (kb.exists && kb.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", node.identifier, node.label)).firstMatch.exists)
        if isKey || !kb.exists || !kb.frame.contains(CGPoint(x: r.midX, y: r.midY)) { return .clear(node, r) }
        let covered: [String: Any] = ["ok": false, "error": "COVERED", "mode": "lean", "coveredBy": "keyboard",
                                      "id": node.identifier, "label": node.label, "x": jnum(r.midX), "y": jnum(r.midY)]
        let focused = app.descendants(matching: .any)
            .matching(NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        let single = focused.exists && [.textField, .secureTextField].contains(focused.elementType)
        let safeKey = kb.buttons.matching(NSPredicate(format: "label ==[c] 'return' OR label ==[c] 'done'")).firstMatch.exists
        guard single && safeKey else { return .answer(covered) }
        if (p["dryRun"] as? Bool) == true {
            return .answer(["ok": true, "dryRun": true, "mode": "lean", "keyboardClose": true, "id": node.identifier,
                            "label": node.label, "x": jnum(r.midX), "y": jnum(r.midY)])
        }
        guard g.mayTouch() else { return .answer(tooLate) }
        app.typeText("\n")
        let kbEnd = Date().addingTimeInterval(1.0)
        while Date() < kbEnd && kb.exists { usleep(150_000) }
        var after: (XCUIElementSnapshot, CGRect)? = nil
        if picked, let root = try? app.snapshot() {
            let pick = snapshotPick(flattenSnapshot(root), query: (p["query"] as? String) ?? "",
                                    type: mapType(p["type"] as? String ?? "any"), index: 0,
                                    withLabel: p["withLabel"] as? String)
            if !pick.covered, let n = pick.node, let nr = pick.rect { after = (n, nr) }
        } else if !picked, let s = try? el.snapshot(), let v = visiblePart(s.frame, in: app) {
            after = (s, v)
        }
        guard let (n, v) = after, !(kb.exists && kb.frame.contains(CGPoint(x: v.midX, y: v.midY))) else {
            return .answer(covered)
        }
        return .clear(n, v)
    }

    /// The full tap: resolve() with containers, contains and other processes. Main thread only.
    /// Before any /launch only SpringBoard or another bundle can be read, and coordinates are taken
    /// from that tree.
    private func liveTap(_ launched: XCUIApplication?, _ p: [String: Any], timeout: Double, resolveDeadline: Date,
                         guard g: TouchGuard, tappedElement: LockedValue<[String: Any]?>) -> [String: Any] {
        drainAlerts(springboard)
        guard let tree = target(p) else { return ["ok": false, "error": "NO_APP"] }
        let app = launched ?? tree
        guard let el = resolve(tree, p, waitTimeout: timeout, deadline: resolveDeadline) else {
            return pressReturnKey(app, p, g) ?? ["ok": false, "error": "NO_MATCH"]
        }
        if !el.waitForExistence(timeout: 1) { return ["ok": false, "error": "NOT_FOUND"] }
        let f = el.frame
        // A partly visible control (e.g. a chip past the screen edge) is tapped on its visible part.
        guard let vis = visiblePart(f, in: app) else {
            return ["ok": false, "error": "OFF_SCREEN", "x": jnum(f.midX), "y": jnum(f.midY)]
        }
        // Read everything before the tap: if the tap removes the element, later reads make XCTest
        // retry for ~20 s and the request times out even though the tap landed.
        let ident = el.identifier
        let fpLabel = el.label, fpValue = (el.value as? String) ?? "", fpSelected = el.isSelected
        let settleDeadline = Date().addingTimeInterval(1.5)
        var hit = el.isHittable
        while !hit && Date() < settleDeadline {
            usleep(150_000)
            hit = el.isHittable
        }
        var tf = vis
        if let vis2 = visiblePart(el.frame, in: app) { tf = vis2 }
        var res = tapResult(tf, ident)
        res["elementType"] = typeName(el.elementType)
        res["label"] = fpLabel
        res["value"] = fpValue
        res["selected"] = fpSelected
        if !onScreenFrame(f, in: app) { res["clamped"] = true }
        if (p["dryRun"] as? Bool) == true {
            res["dryRun"] = true
            return res
        }
        guard g.mayTouch(final: true) else { return tooLate }
        tappedElement.set(["id": ident, "label": fpLabel, "value": fpValue, "selected": fpSelected,
                           "elementType": typeName(el.elementType)])
        if hit {
            el.tap()
        } else {
            tapCenter(app, tf)
        }
        return res
    }

    /// The return key's label changes with the field (return, next, go, done, ...). A tap asking
    /// for any of them while a keyboard is up means "press return". Nil otherwise.
    private func pressReturnKey(_ app: XCUIApplication, _ p: [String: Any], _ g: TouchGuard) -> [String: Any]? {
        guard let q = (p["query"] as? String)?.lowercased(),
              ["return", "next", "go", "done", "search", "send", "join", "enter"].contains(q),
              app.keyboards.firstMatch.exists else { return nil }
        if (p["dryRun"] as? Bool) == true { return ["ok": true, "dryRun": true, "returnKey": true] }
        guard g.mayTouch(final: true) else { return tooLate }
        app.typeText("\n")
        return ["ok": true, "returnKey": true, "note": "pressed the keyboard return key via typeText(\\n)"]
    }

    /// Taps a control that has no id or label of its own, found next to an anchor text: the
    /// `targetType` element on the anchor's row, inside the nearest container that holds both.
    private func handleAnchoredTap(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let anchor = ((p["anchor"] as? String) ?? "").lowercased()
        if anchor.isEmpty { return untouched(["ok": false, "error": "NO_ANCHOR"]) }
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let g = TouchGuard()
        let tt = mapType(p["targetType"] as? String ?? "button")
        let anchorRaw = (p["anchor"] as? String) ?? ""
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            // Nested collection views report off-screen sections at on-screen coordinates, so check
            // that the anchor is really hittable before trusting its frame.
            guard let live = resolve(app, ["query": anchorRaw, "type": "any"], waitTimeout: 1.0),
                  live.isHittable else {
                return ["ok": false, "error": "ANCHOR_NOT_VISIBLE"]
            }
            guard let root = try? app.snapshot() else { return ["ok": false, "error": "NO_SNAPSHOT"] }
            guard let t = anchoredTarget(root: root, anchor: anchor, type: tt, screen: app.frame) else {
                return ["ok": false, "error": "ANCHOR_OR_TARGET_NOT_FOUND"]
            }
            let f = t.frame
            if !onScreenFrame(f, in: app) {
                return ["ok": false, "error": "OFF_SCREEN", "x": jnum(f.midX), "y": jnum(f.midY)]
            }
            guard g.mayTouch(final: true) else { return tooLate }
            tapCenter(app, f)
            return tapResult(f, t.identifier)
        }
        return g.answer(fault, r)
    }

    /// Taps a control on a bar that hides itself after a few seconds: shows the bar and taps the
    /// control in one main-thread call, since a separate /tap round trip can arrive too late.
    private func handleRevealAndTap(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let g = TouchGuard()
        // Off-center by default: the center of a media view is usually play/pause.
        let rnx = p["revealNx"] as? Double ?? 0.25
        let rny = p["revealNy"] as? Double ?? 0.28
        let maxPolls = p["maxPolls"] as? Int ?? 10
        let settleMs = p["settleMs"] as? Double ?? 600
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            // When a query is slower than the bar's lifetime, the caller can pass the target point instead.
            if let tx = p["targetX"] as? Double, let ty = p["targetY"] as? Double {
                // The reveal tap toggles the bar, so only tap it if the bar is hidden.
                if resolve(app, p, waitTimeout: 0.5) == nil {
                    guard g.mayTouch() else { return tooLate }
                    app.coordinate(withNormalizedOffset: CGVector(dx: rnx, dy: rny)).tap()
                    usleep(UInt32(settleMs * 1000))
                }
                guard g.mayTouch(final: true) else { return tooLate }
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: tx, dy: ty)).tap()
                return ["ok": true, "mode": "coord", "x": jnum(tx), "y": jnum(ty)]
            }
            guard g.mayTouch() else { return tooLate }
            app.coordinate(withNormalizedOffset: CGVector(dx: rnx, dy: rny)).tap()
            for _ in 0..<maxPolls {
                if let el = resolve(app, p, waitTimeout: 0.25), el.exists {
                    let f = el.frame
                    if onScreenFrame(f, in: app) {
                        let ident = el.identifier
                        let hittable = el.isHittable
                        guard g.mayTouch(final: true) else { return tooLate }
                        if hittable {
                            el.tap()
                        } else {
                            tapCenter(app, f)
                        }
                        return tapResult(f, ident)
                    }
                }
                usleep(120_000)
            }
            return ["ok": false, "error": "TARGET_NOT_ON_HUD"]
        }
        return g.answer(fault, r)
    }

    // MARK: Type

    private func handleType(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        if appUnderTest.get() == nil && !readsOtherProcess(p) { return noApp(touching: true) }
        let text = p["text"] as? String ?? ""
        // Room for three attempts at 0.8 s per character, never below the usual bound, capped at 150 s.
        // `hard` keeps the sum of all the waits inside that bound.
        let attemptCost: TimeInterval = 4 + 0.8 * Double(text.count)
        let typeBound = min(150.0, max(mainTimeout, 3 * attemptCost))
        let hard = Date().addingTimeInterval(0.9 * typeBound)
        let g = TouchGuard(deadline: hard)
        let (r, fault) = runOnMainBounded([String: Any](), timeout: typeBound) { () -> [String: Any] in
            drainAlerts(self.springboard)
            guard let target = self.target(p) else { return ["ok": false, "error": "NO_APP"] }
            // For fields that can't be queried (e.g. a system purchase sheet); the caller focuses it first.
            if (p["focused"] as? Bool) == true {
                self.waitKeyboardReady(target)
                guard self.typeKeys(target, text, g) else { return tooLate }
                return ["ok": true, "focused": true, "typed": text.count]
            }
            let fieldDeadline = min(Date().addingTimeInterval(p["timeout"] as? Double ?? 8),
                                    hard.addingTimeInterval(-(attemptCost + 5)))
            guard let el = self.waitForField(target, p, until: fieldDeadline, poll: 250_000) else {
                return ["ok": false, "error": "NO_FIELD"]
            }
            guard g.mayTouch() else { return tooLate }
            el.tap()
            self.waitKeyboardReady(target)
            if !self.hasKeyboardFocus(el, in: target) {
                guard g.mayTouch() else { return tooLate }
                el.tap()
                self.waitKeyboardReady(target, timeout: 2)
            }
            if !self.hasKeyboardFocus(el, in: target) { return ["ok": false, "error": "NOT_FOCUSED", "id": el.identifier] }
            return self.typeVerified(text, into: el, target: target, attemptCost: attemptCost, guard: g)
        }
        return g.answer(fault, r)
    }

    /// Polls resolveField (strict) until `deadline`, then asks once more without strict.
    private func waitForField(_ target: XCUIApplication, _ p: [String: Any], until deadline: Date,
                              poll: UInt32) -> XCUIElement? {
        var found = resolveField(target, p)
        while found == nil && Date() < deadline {
            usleep(poll)
            found = resolveField(target, p)
        }
        if found == nil { found = resolveField(target, p, strict: false) }
        return found
    }

    /// Waits until a key exists and the keyboard frame stops moving. With quiescence disabled,
    /// typing during the slide-in animation drops the first characters.
    private func waitKeyboardReady(_ target: XCUIApplication, timeout: TimeInterval = 3) {
        let kb = target.keyboards.firstMatch
        guard kb.keys.firstMatch.waitForExistence(timeout: timeout) else { return }
        let deadline = Date().addingTimeInterval(1.5)
        var last = kb.frame
        while Date() < deadline {
            usleep(120_000)
            let now = kb.frame
            if now.equalTo(last) { return }
            last = now
        }
    }

    /// Whether `el` is the field with keyboard focus. hasFocus is unreliable on some apps' fields,
    /// and typing into an unfocused element makes XCTest retry for ~25 s.
    private func hasKeyboardFocus(_ el: XCUIElement, in target: XCUIApplication) -> Bool {
        let focused = target.descendants(matching: el.elementType)
            .matching(NSPredicate(format: "hasKeyboardFocus == 1")).firstMatch
        guard focused.exists else { return false }
        let a = focused.frame, b = el.frame
        guard a.midX.isFinite, a.midY.isFinite, b.midX.isFinite, b.midY.isFinite else { return true }
        return abs(a.midX - b.midX) < 2 && abs(a.midY - b.midY) < 2
    }

    /// Types one character per call through the app, not the element. Element-level and
    /// multi-character typeText both lost characters in practice. Each call takes about 0.65 s;
    /// /type budgets 0.8 s per character for margin. False if the touch deadline stopped it. The
    /// last character counts as the route's action (`done`); the ones before it do not.
    private func typeKeys(_ target: XCUIApplication, _ text: String, _ g: TouchGuard) -> Bool {
        let last = text.count - 1
        for (k, ch) in text.enumerated() {
            guard g.mayTouch(final: k == last) else { return false }
            target.typeText(String(ch))
            usleep(30_000)
        }
        return true
    }

    /// The field's text, with a placeholder counted as empty. A vanished field reads as empty.
    private func fieldText(_ el: XCUIElement) -> String {
        guard el.exists else { return "" }
        let cur = (el.value as? String) ?? ""
        return cur == (el.placeholderValue ?? "") ? "" : cur
    }

    private func waitUntilEmpty(_ el: XCUIElement, hard: Date) -> Bool {
        let end = min(hard, Date().addingTimeInterval(1.5))
        while !fieldText(el).isEmpty && Date() < end { usleep(150_000) }
        return fieldText(el).isEmpty
    }

    /// Taps past the end of the text but clear of the trailing 48 pt, where a show/hide password
    /// button usually sits.
    private func moveCaretToEnd(_ el: XCUIElement, _ target: XCUIApplication, _ g: TouchGuard) {
        let f = el.frame
        guard f.width > 1, f.height > 1, f.maxX.isFinite, f.midY.isFinite, g.mayTouch() else { return }
        let x = max(f.minX + 8, min(f.maxX - 0.02 * f.width - 1, f.maxX - 48))
        tapCenter(target, CGRect(x: x - 1, y: f.midY - 1, width: 2, height: 2))
    }

    /// Clears the field and confirms it is empty. Checks `exists` before each step, because every
    /// read of a vanished element makes XCTest retry for seconds. False also when the touch
    /// deadline has passed.
    private func clearField(_ el: XCUIElement, _ target: XCUIApplication, _ g: TouchGuard) -> Bool {
        let hard = g.deadline
        if fieldText(el).isEmpty { return true }
        guard g.mayTouch() else { return false }
        el.press(forDuration: 1.0)
        let selectAll = target.menuItems["Select All"]   // English is the default launch language
        if selectAll.waitForExistence(timeout: 2) {
            guard g.mayTouch() else { return false }
            selectAll.tap()
            guard el.exists, g.mayTouch() else { return false }
            el.typeText(XCUIKeyboardKey.delete.rawValue)
            if waitUntilEmpty(el, hard: hard) { return true }
        }
        moveCaretToEnd(el, target, g)
        guard el.exists, g.mayTouch() else { return false }
        el.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fieldText(el).count + 5))
        return waitUntilEmpty(el, hard: hard)
    }

    /// typeText occasionally drops characters, so clear, type, read back and retry (3 attempts).
    /// A secure field shows one bullet per character, so at least its length can be checked.
    private func typeVerified(_ text: String, into el: XCUIElement, target: XCUIApplication,
                              attemptCost: TimeInterval, guard g: TouchGuard) -> [String: Any] {
        let hard = g.deadline
        let secure = el.elementType == .secureTextField
        func readBack() -> String { el.exists ? ((el.value as? String) ?? "") : "" }
        func matches(_ got: String) -> Bool { secure ? got.count == text.count : got == text }
        var got = "", attempts = 0
        while attempts < 3 && Date() < hard.addingTimeInterval(-attemptCost) {
            attempts += 1
            g.startAttempt()
            let cleared = clearField(el, target, g)
            guard el.exists else { return ["ok": false, "error": "FIELD_GONE", "id": el.identifier, "attempts": attempts] }
            guard cleared else { continue }
            guard typeKeys(target, text, g) else { return tooLate.merging(["attempts": attempts]) { $1 } }
            guard el.exists else { return ["ok": false, "error": "FIELD_GONE", "id": el.identifier, "attempts": attempts] }
            let settle = min(hard, Date().addingTimeInterval(1.5))
            got = readBack()
            while !matches(got) && Date() < settle {
                usleep(150_000)
                got = readBack()
            }
            if matches(got) {
                var res: [String: Any] = ["ok": true, "attempts": attempts, "elementType": typeName(el.elementType),
                                          "placeholder": el.placeholderValue ?? "", "id": el.identifier]
                if secure {
                    res["secure"] = true
                    res["maskLen"] = got.count
                } else {
                    res["value"] = got
                }
                return res
            }
        }
        if attempts < 3 {
            return ["ok": false, "error": "TYPE_DEADLINE", "attempts": attempts,
                    "expectedLen": text.count, "gotLen": got.count]
        }
        return secure ? ["ok": false, "error": "SECURE_LEN_MISMATCH", "maskLen": got.count, "expectedLen": text.count]
                      : ["ok": false, "error": "TYPE_MISMATCH", "value": got, "expected": text]
    }

    // MARK: Read the screen

    private func handleFind(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        if appUnderTest.get() == nil && !readsOtherProcess(p) { return noApp() }
        let wait = p["timeout"] as? Double ?? 1.0
        // Presence check ("hittable": false): first live match plus one snapshot of it. No scan over
        // off-screen copies and no whole-screen snapshot, both of which can stall heavy screens.
        let query = (p["query"] as? String) ?? ""
        if (p["hittable"] as? Bool) == false, (p["field"] as? Bool) != true, p["container"] == nil,
           (p["contains"] as? Bool) != true, (p["index"] as? Int ?? 0) == 0, p["withLabel"] == nil, !query.isEmpty {
            let etype = mapType(p["type"] as? String ?? "any")
            let (pr, pfault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
                drainAlerts(self.springboard)
                let deadline = Date().addingTimeInterval(wait)
                guard let tree = self.target(p) else { return ["ok": false, "error": "NO_APP"] }
                let scope = tree.descendants(matching: etype)
                var found: XCUIElement? = nil
                for pred in [exactMatch(query), partialMatch(query)] {
                    let el = scope.matching(pred).firstMatch
                    let budget = max(0.2, deadline.timeIntervalSinceNow)
                    if el.waitForExistence(timeout: budget) {
                        found = el
                        break
                    }
                }
                guard let el = found, let n = try? el.snapshot() else { return ["found": false, "determinate": true, "mode": "presence"] }
                let f = n.frame
                return ["found": true, "determinate": true, "hittable": NSNull(), "elementType": typeName(n.elementType),
                        "selected": n.isSelected, "value": (n.value as? String) ?? "", "label": n.label,
                        "id": n.identifier, "x": jnum(f.midX), "y": jnum(f.midY), "w": jnum(f.width),
                        "h": jnum(f.height), "mode": "presence"]
            }
            return respOr(pfault, pr)
        }
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            guard let tree = self.target(p) else { return ["ok": false, "error": "NO_APP"] }
            let el: XCUIElement
            if (p["field"] as? Bool) == true {
                // Same lookup as /type, so a wait for a field asks the same question.
                guard let field = self.waitForField(tree, p, until: Date().addingTimeInterval(wait), poll: 200_000)
                else { return ["found": false, "determinate": true, "field": true] }
                el = field
            } else {
                guard let match = resolve(tree, p, waitTimeout: wait, deadline: Date().addingTimeInterval(wait))
                else { return ["found": false, "determinate": true] }
                el = match
            }
            let f = el.frame
            // isHittable is a hit test, and some tap-anywhere overlays dismiss themselves on it.
            let hittable: Any = (p["hittable"] as? Bool) == false ? NSNull() : el.isHittable
            return ["found": true, "determinate": true, "hittable": hittable, "elementType": typeName(el.elementType),
                    "selected": el.isSelected, "value": (el.value as? String) ?? "",
                    "label": el.label, "id": el.identifier,
                    "x": jnum(f.midX), "y": jnum(f.midY),
                    "w": jnum(f.width), "h": jnum(f.height)]
        }
        return respOr(fault, r)
    }

    /// Lists interactive elements from one whole-app snapshot. Per-element live queries can take
    /// minutes on dense screens; a snapshot takes well under a second.
    private func handleDescribe(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        if appUnderTest.get() == nil && !readsOtherProcess(p) { return noApp() }
        let cap = p["max"] as? Int ?? 40
        var wanted: [XCUIElement.ElementType: String] = [
            .button: "button", .textField: "textField", .secureTextField: "secureTextField",
            .switch: "switch", .searchField: "searchField",
        ]
        if (p["includeCells"] as? Bool) == true { wanted[.cell] = "cell" }
        if (p["includeText"] as? Bool) == true { wanted[.staticText] = "staticText" }
        // Lists repeat the same id once per row; capping per id keeps distinct controls within `max`.
        let maxPerId = p["maxPerId"] as? Int ?? 6
        let (els, fault) = runOnMainBounded([[String: Any]]()) { () -> [[String: Any]] in
            drainAlerts(self.springboard)
            guard let root = try? self.target(p)?.snapshot() else { return [] }
            var out: [[String: Any]] = []
            var perId: [String: Int] = [:]
            func walk(_ s: XCUIElementSnapshot) {
                if out.count >= cap { return }
                var name = wanted[s.elementType]
                // Images and "other" elements only when they carry an id; anonymous containers would flood the list.
                if name == nil, s.elementType == .image || s.elementType == .other, !s.identifier.isEmpty {
                    name = (s.elementType == .image) ? "image" : "other"
                }
                if let name = name {
                    var emit = true
                    if !s.identifier.isEmpty {
                        let n = perId[s.identifier] ?? 0
                        if n >= maxPerId { emit = false } else { perId[s.identifier] = n + 1 }
                    }
                    if emit {
                        let f = s.frame
                        out.append(["type": name, "id": s.identifier, "label": s.label,
                                    "value": (s.value as? String) ?? "",
                                    "selected": s.isSelected, "enabled": s.isEnabled,
                                    "x": jnum(f.midX), "y": jnum(f.midY),
                                    "w": jnum(f.width), "h": jnum(f.height)])
                    }
                }
                for c in s.children {
                    if out.count >= cap { break }
                    walk(c)
                }
            }
            walk(root)
            return out
        }
        if let f = fault { return faultResponse(f, extra: ["elements": []]) }
        return jsonResp(["ok": true, "count": els.count, "elements": els])
    }

    /// Reports which of several strings are on screen, from one snapshot (substring match on id,
    /// label and value). Unlike /describe there is no cap, which matters because an overlay is
    /// usually the last thing in the tree. `scope: "springboard"` or `target` covers system sheets.
    private func handleProbe(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let queries = (p["queries"] as? [String] ?? []).filter { !$0.isEmpty }
        if queries.isEmpty { return jsonResp(["ok": true, "present": []]) }
        let springboardScope = (p["scope"] as? String) == "springboard"
        if appUnderTest.get() == nil && !readsOtherProcess(p) { return noApp() }
        let needles = queries.map { $0.lowercased() }
        let (hits, fault) = runOnMainBounded(Set<Int>()) { () -> Set<Int> in
            if !springboardScope { drainAlerts(self.springboard) }   // would dismiss what we're probing for
            guard let root = try? self.target(p)?.snapshot() else { return [] }
            var found = Set<Int>()
            func walk(_ s: XCUIElementSnapshot) {
                if found.count == needles.count { return }
                let fields = [s.identifier, s.label, (s.value as? String) ?? ""]
                    .filter { !$0.isEmpty }.map { $0.lowercased() }
                for (i, n) in needles.enumerated() where !found.contains(i) {
                    if fields.contains(where: { $0.contains(n) }) { found.insert(i) }
                }
                for c in s.children {
                    if found.count == needles.count { return }
                    walk(c)
                }
            }
            walk(root)
            return found
        }
        if let f = fault { return faultResponse(f, extra: ["present": []]) }
        return jsonResp(["ok": true, "present": hits.sorted().map { queries[$0] }])
    }

    // MARK: Scroll and drag

    private func handleScroll(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let dir = p["direction"] as? String ?? "up"
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            guard g.mayTouch(final: true) else { return tooLate }
            switch dir {
            case "down": app.swipeDown()
            case "left": app.swipeLeft()
            case "right": app.swipeRight()
            default: app.swipeUp()
            }
            return ["ok": true]
        }
        return g.answer(fault, r)
    }

    /// Scrolls in small steps until `query` is hittable. A full swipe can jump a target right past
    /// the visible area, and frames of off-screen sections can't be trusted, so isHittable decides.
    private func handleScrollTo(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let query = (p["query"] as? String) ?? ""
        if query.isEmpty { return untouched(["ok": false, "error": "NO_QUERY"], 400) }
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let g = TouchGuard()
        // Stop before the main-thread bound and say so; the client continues with noLoadWait.
        let blockDeadline = Date().addingTimeInterval(0.8 * mainTimeout)
        let loadWait = (p["noLoadWait"] as? Bool) == true ? 0.6 : 12.0
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            // Center mode always moves the target: a control under the keyboard reads as hittable.
            let center = (p["center"] as? Bool) == true
            // Look quickly first. Only if nothing matches at all, wait longer: the screen may still
            // be loading, and swiping now would scroll past the target.
            var found: XCUIElement? = nil
            if let quick = self.locate(app, query, wait: 0.6) {
                found = quick
                if quick.isHittable && !center { return ["ok": true, "steps": 0, "note": "already on screen"] }
            } else if let late = self.locate(app, query, wait: loadWait) {
                found = late
                if late.isHittable && !center { return ["ok": true, "steps": 0, "note": "already on screen (after load wait)"] }
            }
            if center, let el = found, let answer = self.centerInView(app, el, until: blockDeadline, guard: g) {
                return answer
            }
            return self.scrollInSteps(app, p, query: query, seen: found != nil, until: blockDeadline, guard: g)
        }
        return g.answer(fault, r)
    }

    private func locate(_ app: XCUIApplication, _ query: String, wait: Double) -> XCUIElement? {
        return resolve(app, ["query": query, "type": "any"], waitTimeout: wait,
                       deadline: Date().addingTimeInterval(wait))
    }

    /// The band a target should end up in: below the header, above the keyboard or the tab bar.
    /// Drags that start on the keyboard do nothing, and drags that start on a bar docked above the
    /// tab bar can open it.
    private func visibleBand(_ app: XCUIApplication, _ screen: CGRect) -> (top: CGFloat, bottom: CGFloat) {
        let kb = app.keyboards.firstMatch
        let top = screen.minY + screen.height * 0.12
        if kb.exists && kb.frame.height > 1 { return (top, min(kb.frame.minY, screen.maxY)) }
        let tab = app.tabBars.firstMatch
        let tabTop = tab.exists && tab.frame.height > 1 ? tab.frame.minY : screen.maxY
        return (top, min(screen.minY + screen.height * 0.8, tabTop - 70))
    }

    /// Center mode (opt-in, for retrying a COVERED or OFF_SCREEN tap): drags the target to the middle
    /// of the visible band with slow, measured drags. Nil when it didn't get there.
    private func centerInView(_ app: XCUIApplication, _ el: XCUIElement, until deadline: Date,
                              guard g: TouchGuard) -> [String: Any]? {
        let screen = app.frame
        var lastMid: CGFloat?
        var drags = 0
        for i in 1...4 {
            if Date() >= deadline || !el.exists { break }
            let (top, bottom) = visibleBand(app, screen)
            let height = bottom - top
            if height < 80 { break }
            let mid = el.frame.midY
            if !mid.isFinite { break }
            if let last = lastMid, abs(mid - last) < 4 { break }
            lastMid = mid
            let dy = mid - (top + height / 2)
            if abs(dy) < height * 0.2 {
                if el.isHittable { return ["ok": true, "steps": i - 1, "centered": true] }
                break
            }
            let dist = max(-(height - 40), min(height - 40, dy))
            let y1 = dist > 0 ? bottom - 20 : top + 20
            let origin = app.coordinate(withNormalizedOffset: .zero)
            guard g.mayTouch(final: true) else { return tooLate }
            origin.withOffset(CGVector(dx: screen.midX, dy: y1))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: screen.midX, dy: y1 - dist)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            drags += 1
            usleep(300_000)
        }
        if el.exists && el.isHittable && el.frame.midY < visibleBand(app, screen).bottom {
            return ["ok": true, "steps": drags, "centered": true]
        }
        return nil
    }

    /// Swipes `step` of the screen at a time until the target is hittable, reversing once at the end
    /// of a list. `goingDown` and `reversed` let a call that ran out of time be continued.
    private func scrollInSteps(_ app: XCUIApplication, _ p: [String: Any], query: String, seen wasSeen: Bool,
                               until deadline: Date, guard g: TouchGuard) -> [String: Any] {
        let maxSteps = p["maxSteps"] as? Int ?? 12
        let step = CGFloat(p["step"] as? Double ?? 0.30)      // fraction of the screen per swipe
        var seen = wasSeen
        var goingDown = (p["goingDown"] as? Bool) ?? true     // page-wise down == finger up
        var reversed = (p["reversed"] as? Bool) ?? false
        var lastY: CGFloat?
        for i in 1...maxSteps {
            if Date() >= deadline {
                return ["ok": false, "error": "NOT_REACHED", "steps": i - 1, "deadline": true, "seen": seen,
                        "goingDown": goingDown, "reversed": reversed]
            }
            let from = goingDown ? CGFloat(0.75) : CGFloat(0.35)
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: goingDown ? from - step : from + step))
            guard g.mayTouch(final: true) else { return tooLate }
            a.press(forDuration: 0.05, thenDragTo: b)
            usleep(500_000)
            guard let el = locate(app, query, wait: 0.6) else {
                lastY = nil
                continue
            }
            seen = true
            if el.isHittable { return ["ok": true, "steps": i, "y": jnum(el.frame.midY)] }
            // No movement means the end of the list: try the other direction once.
            let y = el.frame.midY
            if let last = lastY, abs(y - last) < 1.0 {
                if reversed { return ["ok": false, "error": "END_OF_LIST", "steps": i] }
                goingDown = !goingDown
                reversed = true
            }
            lastY = y
        }
        return ["ok": false, "error": "NOT_REACHED", "steps": maxSteps]
    }

    private func handleDrag(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        guard let nx1 = p["nx1"] as? Double, let ny1 = p["ny1"] as? Double,
              let nx2 = p["nx2"] as? Double, let ny2 = p["ny2"] as? Double else {
            return untouched(["ok": false, "error": "BAD_COORDS", "detail": "need nx1, ny1, nx2, ny2 (0..1)"], 400)
        }
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let dur = p["duration"] as? Double ?? 0.6
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: nx1, dy: ny1))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: nx2, dy: ny2))
            guard g.mayTouch(final: true) else { return tooLate }
            a.press(forDuration: dur, thenDragTo: b)
            return ["ok": true]
        }
        return g.answer(fault, r)
    }

    // MARK: Alerts, pickers, back, screenshot

    /// Accepts a permission alert through SpringBoard. `wait` is a single grace period for an alert
    /// to appear; pass 0 for an instant answer.
    private func handlePermission(_ body: String) -> (Int, String, Data) {
        let p = parseJSON(body)
        let labels: [String] = (p["button"] as? String).map { [$0] } ?? alertAcceptLabels
        let grace = p["wait"] as? Double ?? 2.0
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            let notAnswered: [String: Any] = ["ok": false, "button": ""]
            let alert = self.springboard.alerts.firstMatch
            if grace > 0, !alert.exists {
                _ = alert.waitForExistence(timeout: grace)
            }
            if alert.exists {
                let text = alertText(alert)
                if !permissionAlertMarkers.contains(where: { text.contains($0) }) {
                    unexpectedAlert.set(String(alert.label.prefix(200)))
                    return notAnswered
                }
                unexpectedAlert.set("")
            }
            // Searched across SpringBoard because some prompts (location precision) are not alerts.
            for l in labels where self.springboard.buttons[l].exists {
                guard g.mayTouch(final: true) else { return tooLate }
                self.springboard.buttons[l].tap()
                return ["ok": true, "button": l]
            }
            return notAnswered
        }
        var answer = r
        let stuck = unexpectedAlert.get()
        if !stuck.isEmpty { answer["unexpectedAlert"] = stuck }
        return g.answer(fault, answer)
    }

    // values: one per picker wheel, left to right.
    private func handleSetPicker(_ body: String) -> (Int, String, Data) {
        let values = parseJSON(body)["values"] as? [String] ?? []
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            let wheels = app.pickerWheels
            let n = wheels.count
            if n == 0 { return ["ok": false, "error": "NO_PICKER"] }
            // adjust() scrolls even when the wheel already shows the value, which some forms react to.
            func needsTurning(_ j: Int) -> Bool { (wheels.element(boundBy: j).value as? String) != values[j] }
            var turned = 0
            for (i, v) in values.enumerated() where i < n {
                let wheel = wheels.element(boundBy: i)
                if (wheel.value as? String) == v { continue }
                // The last wheel still to turn is the route's action; the ones before it only prepare it.
                let isLast = !((i + 1)..<min(values.count, n)).contains(where: needsTurning)
                guard g.mayTouch(final: isLast) else { return tooLate.merging(["wheels": n, "turned": turned]) { $1 } }
                wheel.adjust(toPickerWheelValue: v)
                turned += 1
            }
            return ["ok": true, "wheels": n, "turned": turned]
        }
        return g.answer(fault, r)
    }

    /// Taps the navigation bar's back button (left edge, labelled "Back" or unlabelled), which is
    /// more reliable than an edge swipe. Falls back to the swipe, or with `buttonOnly` answers
    /// NO_NAV_BACK. Buttons labelled Close or Cancel are never tapped.
    private func handleBack(_ body: String) -> (Int, String, Data) {
        let buttonOnly = (parseJSON(body)["buttonOnly"] as? Bool) == true
        guard let app = appUnderTest.get() else { return noApp(touching: true) }
        let g = TouchGuard()
        let (r, fault) = runOnMainBounded([String: Any]()) { () -> [String: Any] in
            drainAlerts(self.springboard)
            let screen = app.frame
            let bars = app.navigationBars
            for i in 0..<min(bars.count, 4) {
                let bar = bars.element(boundBy: i)
                guard onScreenFrame(bar.frame, in: app) else { continue }
                let b = bar.buttons.element(boundBy: 0)
                guard b.exists else { continue }
                let f = b.frame
                let label = b.label
                guard f.midX < screen.width * 0.25, label.isEmpty || label == "Back",
                      onScreenFrame(f, in: app), b.isHittable else { continue }
                guard g.mayTouch(final: true) else { return tooLate }
                tapCenter(app, f)
                return ["ok": true, "mode": "button", "x": jnum(f.midX), "y": jnum(f.midY)]
            }
            if buttonOnly { return ["ok": false, "error": "NO_NAV_BACK"] }
            let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            guard g.mayTouch(final: true) else { return tooLate }
            a.press(forDuration: 0.3, thenDragTo: b)
            return ["ok": true, "mode": "swipe"]
        }
        return g.answer(fault, r)
    }

    private func handleScreenshot() -> (Int, String, Data) {
        let (png, fault) = runOnMainBounded(Data()) { XCUIScreen.main.screenshot().pngRepresentation }
        if let f = fault { return faultResponse(f) }
        return (200, "image/png", png)
    }
}
