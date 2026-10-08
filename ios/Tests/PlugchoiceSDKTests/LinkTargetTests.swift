import XCTest
@testable import PlugchoiceSDK

/// Opening the screen (PROTOCOL §2): the URL for an action, the one
/// allowed origin, the debug host override, and the public entry points.
final class LinkTargetTests: XCTestCase {
    // MARK: - The URL

    func testAddChargerOpensTheConnectHost() {
        let target = LinkTarget(action: .addCharger(), hostOverride: nil, honourOverride: true)
        XCTAssertEqual(target.url.absoluteString, "https://connect.plugchoice.com/#action=add")
        XCTAssertEqual(target.allowedOrigin.description, "https://connect.plugchoice.com")
        XCTAssertEqual(target.action, "add")
    }

    func testEveryActionAndItsIds() {
        let cases: [(LinkAction, String)] = [
            (.addCharger(siteId: "site-1"), "#action=add&site_id=site-1"),
            (.setup(chargerId: "c-1"), "#action=setup&charger_id=c-1"),
            (.reconnect(chargerId: "c-1"), "#action=reconnect&charger_id=c-1"),
            (.custom("diagnose", chargerId: "c-1"), "#action=diagnose&charger_id=c-1"),
            (.custom("later"), "#action=later"),
            (LinkAction(action: "add", chargerId: "c-1", siteId: "s-1"), "#action=add&charger_id=c-1&site_id=s-1"),
            (.addCharger(siteId: ""), "#action=add"),
        ]
        for (action, fragment) in cases {
            let url = LinkTarget(action: action, hostOverride: nil, honourOverride: false).url.absoluteString
            XCTAssertEqual(url, "https://connect.plugchoice.com/" + fragment, "\(action)")
        }
    }

    func testValuesArePercentEncoded() {
        let action = LinkAction(action: "a b&c", chargerId: "id/with?#&=%", siteId: "ü")
        let url = LinkTarget(action: action, hostOverride: nil, honourOverride: false).url
        XCTAssertEqual(
            url.absoluteString,
            "https://connect.plugchoice.com/#action=a%20b%26c&charger_id=id%2Fwith%3F%23%26%3D%25&site_id=%C3%BC"
        )
        XCTAssertEqual(url.host, "connect.plugchoice.com", "an id never changes the host")
        XCTAssertEqual(LinkTarget.percentEncoded("AZaz09-._~"), "AZaz09-._~")
    }

    func testTheOnlyAllowedOriginIsTheConnectHost() {
        let target = LinkTarget(action: .addCharger(), hostOverride: nil, honourOverride: true)
        let allowList = OriginAllowList([target.allowedOrigin])
        XCTAssertTrue(allowList.allows(url: target.url))
        XCTAssertTrue(allowList.allows(url: URL(string: "https://connect.plugchoice.com:443/other")))
        XCTAssertFalse(allowList.allows(url: URL(string: "http://connect.plugchoice.com/")))
        XCTAssertFalse(allowList.allows(url: URL(string: "https://link.plugchoice.com/")), "a host other than connect.plugchoice.com")
        XCTAssertFalse(allowList.allows(url: URL(string: "https://app.plugchoice.com/")))
    }

    // MARK: - hostOverride

    func testOverrideReplacesSchemeHostAndPortInDebug() {
        let target = LinkTarget(action: .reconnect(chargerId: "c-1"), hostOverride: "http://192.168.1.20:5173", honourOverride: true)
        XCTAssertEqual(target.url.absoluteString, "http://192.168.1.20:5173/#action=reconnect&charger_id=c-1")
        XCTAssertEqual(target.allowedOrigin.description, "http://192.168.1.20:5173")
        let allowList = OriginAllowList([target.allowedOrigin])
        XCTAssertTrue(allowList.allows(url: target.url))
        XCTAssertFalse(allowList.allows(url: URL(string: "https://connect.plugchoice.com/")), "the override is the only origin")
    }

    func testOverrideVariants() {
        let cases: [(override: String, url: String, origin: String)] = [
            ("http://192.168.1.20:5173/", "http://192.168.1.20:5173/#action=add", "http://192.168.1.20:5173"),
            ("  https://link-ui.local  ", "https://link-ui.local/#action=add", "https://link-ui.local"),
            ("http://localhost:4173", "http://localhost:4173/#action=add", "http://localhost:4173"),
            ("http://[::1]:5173", "http://[::1]:5173/#action=add", "http://[::1]:5173"),
        ]
        for item in cases {
            let target = LinkTarget(action: .addCharger(), hostOverride: item.override, honourOverride: true)
            XCTAssertEqual(target.url.absoluteString, item.url, item.override)
            XCTAssertEqual(target.allowedOrigin.description, item.origin, item.override)
        }
    }

    func testOverrideIsIgnoredOutsideDebug() {
        let target = LinkTarget(action: .addCharger(), hostOverride: "http://192.168.1.20:5173", honourOverride: false)
        XCTAssertEqual(target.url.absoluteString, "https://connect.plugchoice.com/#action=add")
        XCTAssertEqual(target.allowedOrigin.description, "https://connect.plugchoice.com")
    }

    func testMalformedOverrideIsIgnored() {
        for override in ["192.168.1.20:5173", "ftp://192.168.1.20", "http://", "http://host/path", "http://host/?q=1", "http://user@host", "http://host#x", " "] {
            let target = LinkTarget(action: .addCharger(), hostOverride: override, honourOverride: true)
            XCTAssertEqual(target.url.absoluteString, "https://connect.plugchoice.com/#action=add", override)
            XCTAssertEqual(target.allowedOrigin.description, "https://connect.plugchoice.com", override)
        }
    }

    // MARK: - Public API

    func testActions() {
        XCTAssertEqual(LinkAction.addCharger(), LinkAction(action: "add"))
        XCTAssertEqual(LinkAction.addCharger(siteId: "s"), LinkAction(action: "add", siteId: "s"))
        XCTAssertEqual(LinkAction.setup(chargerId: "c"), LinkAction(action: "setup", chargerId: "c"))
        XCTAssertEqual(LinkAction.reconnect(chargerId: "c"), LinkAction(action: "reconnect", chargerId: "c"))
        XCTAssertEqual(LinkAction.custom("x", chargerId: "c"), LinkAction(action: "x", chargerId: "c"))
        let reconnect = LinkAction.reconnect(chargerId: "c")
        XCTAssertEqual([reconnect.action, reconnect.chargerId, reconnect.siteId], ["reconnect", "c", nil])
    }

    func testTransportsInTheTestHost() {
        // The simulator has no Bluetooth and the test host declares no
        // Bonjour services.
        XCTAssertEqual(Plugchoice.transports(), ["wifi", "http", "socket"])
    }

    func testTheSDKVersionIsSemver() {
        // Not a fixed value: release-please bumps it.
        XCTAssertNotNil(Plugchoice.sdkVersion.range(of: #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression), Plugchoice.sdkVersion)
    }

    func testBluetoothNeedsTheUsageDescriptionAndARadio() {
        XCTAssertTrue(BluetoothSupport.isAvailable(hasUsageDescription: true, hasBluetoothLE: true))
        XCTAssertFalse(BluetoothSupport.isAvailable(hasUsageDescription: false, hasBluetoothLE: true))
        XCTAssertFalse(BluetoothSupport.isAvailable(hasUsageDescription: true, hasBluetoothLE: false))
        XCTAssertFalse(BluetoothSupport.isAvailable, "the test host has no NSBluetoothAlwaysUsageDescription")
    }

    @MainActor
    func testAScreenClosedByTheHostReportsTheOpenedAction() throws {
        let plugchoice = Plugchoice(fetchClientSecret: { _ in "cs_test_secret" })
        var result: LinkResult?
        let controller = plugchoice.link.makeController(.reconnect(chargerId: "c-1")) { result = $0 }
        controller.closeForHost()
        XCTAssertEqual(result, LinkResult(status: .cancelled, action: "reconnect"))
    }

    @MainActor
    func testTheShellsOwnResults() {
        XCTAssertEqual(
            LinkViewController.ownResult(action: "add", loadErrorMessage: nil),
            LinkResult(status: .cancelled, action: "add", sessionId: nil, devices: [], error: nil)
        )
        XCTAssertEqual(
            LinkViewController.ownResult(action: "reconnect", loadErrorMessage: "offline"),
            LinkResult(status: .error, action: "reconnect", error: LinkError(code: "pageLoadFailed", message: "offline"))
        )
    }

    @MainActor
    func testThePrefetchGetsTheOpenedAction() async throws {
        let received = ActionLog()
        let plugchoice = Plugchoice(fetchClientSecret: { action in
            await received.add(action)
            return "cs_test_secret"
        })
        let controller = plugchoice.link.makeController(.setup(chargerId: "c-9")) { _ in }
        controller.loadViewIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while await received.actions.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actions = await received.actions
        XCTAssertEqual(actions, [.setup(chargerId: "c-9")], "fetched once when the screen opens, with its action")
        controller.closeForHost()
    }

    func testResultDescription() {
        let result = LinkResult(status: .success, action: "add", sessionId: "s1", devices: [Device(type: "charger", id: "c1")])
        XCTAssertEqual(result.description, "status: success\naction: add\nsessionId: s1\ndevices: [charger c1]")
    }
}

private actor ActionLog {
    private(set) var actions: [LinkAction] = []

    func add(_ action: LinkAction) {
        actions.append(action)
    }
}
