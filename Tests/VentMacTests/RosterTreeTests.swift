import XCTest
import Combine
import CVentrilo3
@testable import VentCore
@testable import VentMac

final class RosterTreeTests: XCTestCase {
    @MainActor
    func testTreeUpdatesForMembershipAndMetadataChanges() {
        let store = ConnectionStore()
        let channel = makeChannel(id: 1, parent: 0, name: "General")
        store.applyRosterEvent(.channelUpserted(channel))
        store.applyRosterEvent(.channelUpserted(makeChannel(id: 2, parent: 1, name: "Games")))
        store.applyRosterEvent(.userUpserted(makeUser(id: 10, channel: 0, name: "Lobby")))
        store.applyRosterEvent(.userUpserted(makeUser(id: 11, channel: 1, name: "Zoe")))
        store.applyRosterEvent(.userUpserted(makeUser(id: 12, channel: 1, name: "Amy")))
        store.applyRosterEvent(.userUpserted(makeUser(id: 13, channel: 1, name: "")))
        XCTAssertEqual(store.treeRows.map(\.id), ["u10", "c1", "u12", "u11", "c2"])
        XCTAssertEqual(store.treeRows.map(\.depth), [0, 0, 1, 1, 1])

        let previousChannel = store.applyRosterEvent(.userUpserted(
            makeUser(id: 11, channel: 2, name: "Zoe", comment: "Playing")))
        XCTAssertEqual(previousChannel, 1)
        XCTAssertEqual(store.treeRows.map(\.id), ["u10", "c1", "u12", "c2", "u11"])
        XCTAssertEqual(store.treeRows.last?.depth, 2)
        if case .user(let user) = store.treeRows.last?.kind {
            XCTAssertEqual(user.comment, "Playing")
        } else {
            XCTFail("Expected the moved user's updated row")
        }

        XCTAssertEqual(store.applyRosterEvent(.userRemoved(11)), 2)
        store.applyRosterEvent(.channelRemoved(2))
        XCTAssertEqual(store.treeRows.map(\.id), ["u10", "c1", "u12"])
        store.applyRosterEvent(.channelUpserted(makeChannel(id: 1, parent: 0, name: "Renamed")))
        if case .channel(let updated) = store.treeRows[1].kind {
            XCTAssertEqual(updated.name, "Renamed")
        } else {
            XCTFail("Expected the renamed channel")
        }
    }

    @MainActor
    func testTalkAndUnrelatedEventsDoNotRepublishTree() {
        let store = ConnectionStore()
        let user = makeUser(id: 10, channel: 0, name: "Amy")
        store.applyRosterEvent(.userUpserted(user))
        var updates = 0
        let subscription = store.$treeRows.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }

        store.applyRosterEvent(.talkStarted(userID: 10, rate: 48000))
        XCTAssertTrue(store.roster.talking.contains(10))
        store.applyRosterEvent(.ping(42))
        store.applyRosterEvent(.chatMessage(userID: 10, message: "Hello"))
        store.applyRosterEvent(.userUpserted(user))
        store.applyRosterEvent(.userRemoved(99))
        store.applyRosterEvent(.channelRemoved(99))
        store.applyRosterEvent(.talkEnded(userID: 10))
        XCTAssertFalse(store.roster.talking.contains(10))
        store.applyRosterEvent(.talkStarted(userID: 10, rate: 48000))
        store.applyRosterEvent(.disconnected)
        XCTAssertTrue(store.roster.talking.isEmpty)
        XCTAssertEqual(updates, 0)

        store.applyRosterEvent(.userRemoved(10))
        XCTAssertEqual(updates, 1)
        XCTAssertTrue(store.treeRows.isEmpty)
    }

    private func makeUser(id: UInt16, channel: UInt16, name: String, comment: String = "") -> V3User {
        var user = v3_user()
        user.id = id
        user.channel = channel
        user.name = strdup(name)
        user.comment = strdup(comment)
        defer { free(user.name); free(user.comment) }
        return V3User(c: user)
    }

    private func makeChannel(id: UInt16, parent: UInt16, name: String) -> V3Channel {
        var channel = v3_channel()
        channel.id = id
        channel.parent = parent
        channel.name = strdup(name)
        defer { free(channel.name) }
        return V3Channel(c: channel)
    }
}
