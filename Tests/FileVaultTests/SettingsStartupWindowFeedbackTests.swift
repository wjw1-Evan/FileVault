import XCTest
@testable import FileVaultCore
@testable import FileVaultApp

/// v4.2.32 closure audit: the settings window can exist before AppState
/// built the service (login launch, --open-ui). Every card action that
/// needs the service must ANSWER on the card's message line — a silent
/// no-op reads as "the button is broken". (addRoot is exempt here: its
/// startup fallback is a modal alert, untestable in a suite.)
@MainActor
final class SettingsStartupWindowFeedbackTests: XCTestCase {

    /// An UNBOUND model: no app → service == nil → the startup window.
    private func makeUnboundModel() -> (SettingsModel, RootCard) {
        let model = SettingsModel()
        let repo = RepoSection(id: "/tmp/vault-x", name: "vault-x")
        let card = RootCard(id: "/tmp/vault-x", name: "vault-x", path: "/tmp/vault-x",
                            paused: false, repo: repo)
        model.rootCards = [card]
        return (model, card)
    }

    private func assertAnswered(_ model: SettingsModel, action: String,
                                line: UInt = #line) {
        let msg = model.rootCards.first?.repo.message ?? ""
        XCTAssertFalse(msg.isEmpty, "\(action) must answer during the startup window", line: line)
        XCTAssertEqual(msg, "应用正在启动，请稍后重试。",
                       "\(action): the answer must be the startup line", line: line)
    }

    func testCardActionsAnswerWhenServiceIsMissing() {
        let (model, card) = makeUnboundModel()
        let id = card.id

        model.pauseRoot(card, to: true)
        assertAnswered(model, action: "pauseRoot")

        model.removeRoot(card)
        assertAnswered(model, action: "removeRoot")

        model.testConnection(id)
        assertAnswered(model, action: "testConnection")

        model.checkIntegrity(id)
        assertAnswered(model, action: "checkIntegrity")

        // Answers BEFORE the relocation panel: the pre-fix flow opened an
        // NSOpenPanel and then vanished after the pick anyway.
        model.relocateRoot(id)
        assertAnswered(model, action: "relocateRoot")

        model.setUpstreamRemote(id, remote: "origin")
        assertAnswered(model, action: "setUpstreamRemote")

        model.repairInterruptedOperation(id)
        assertAnswered(model, action: "repairInterruptedOperation")

        model.openLargeFiles(id)
        assertAnswered(model, action: "openLargeFiles")
    }
}
