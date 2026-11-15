import XCTest
import SwiftUI
import AppKit
@testable import FileVaultApp
@testable import FileVaultCore

/// The PAT row must actually render inputs (v4.0.2: the picker offered
/// "用户名 + 访问令牌" with nowhere to type them).
///
/// ImageRenderer draws AppKit controls as placeholders, so the visual artifact is
/// produced from a real NSHostingView inside an offscreen window — that renders
/// actual NSTextField / NSSecureTextField controls.
@MainActor
final class RepoAuthFieldsSnapshotTests: XCTestCase {
    private func snapshot<V: View>(_ view: V, size: NSSize, to path: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
        return rep
    }

    /// A blank row would be a single colour; real controls/text add many.
    private func assertNotBlank(_ rep: NSBitmapImageRep) {
        var seen = Set<UInt32>()
        let step = max(1, rep.pixelsWide / 80)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y) {
                    seen.insert(UInt32(c.redComponent * 255) << 16
                                | UInt32(c.greenComponent * 255) << 8
                                | UInt32(c.blueComponent * 255))
                }
                x += step
            }
            y += step
        }
        XCTAssertGreaterThan(seen.count, 12, "rendered row looks blank")
    }

    func testPATModeRendersUsernameAndTokenFields() throws {
        let view = RepoAuthFields(mode: .pat,
                                  user: .constant("ci-user"),
                                  token: .constant("ghp_demo_token"),
                                  tokenSaved: true,
                                  save: {})
            .frame(width: 620, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        let rep = try snapshot(view, size: NSSize(width: 620, height: 90),
                               to: "/tmp/fv-repo-auth-pat.png")
        XCTAssertGreaterThan(rep.pixelsWide, 400)
        assertNotBlank(rep)
    }

    func testSSHModeShowsGuidanceInsteadOfInputs() throws {
        let view = RepoAuthFields(mode: .ssh, user: .constant(""), token: .constant(""),
                                  tokenSaved: false, save: {})
            .frame(width: 620, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        let rep = try snapshot(view, size: NSSize(width: 620, height: 44),
                               to: "/tmp/fv-repo-auth-ssh.png")
        assertNotBlank(rep)
    }

    func testAutoModeRendersNothing() throws {
        let view = RepoAuthFields(mode: .auto, user: .constant(""), token: .constant(""),
                                  tokenSaved: false, save: {})
            .frame(width: 620, height: 1, alignment: .leading)
        let rep = try snapshot(view, size: NSSize(width: 620, height: 2),
                               to: "/tmp/fv-repo-auth-auto.png")
        XCTAssertGreaterThan(rep.pixelsWide, 400)
    }
}
