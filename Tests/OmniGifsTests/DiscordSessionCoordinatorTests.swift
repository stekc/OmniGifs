import Foundation
import Testing

@testable import OmniGifs

struct DiscordSessionCoordinatorTests {
    @MainActor
    @Test func acceptsOnlyHTTPSDiscordHostsAndSubdomains() throws {
        let accepted = [
            "https://discord.com/login",
            "https://www.discord.com/app",
            "https://canary.discord.com/channels/@me",
        ]
        let rejected = [
            "http://discord.com/login",
            "https://evildiscord.com/login",
            "https://discord.com.example.net/login",
            "https://example.com/discord.com",
        ]

        for value in accepted {
            let url = try #require(URL(string: value))
            #expect(DiscordSessionCoordinator.isTrustedDiscordURL(url))
        }
        for value in rejected {
            let url = try #require(URL(string: value))
            #expect(!DiscordSessionCoordinator.isTrustedDiscordURL(url))
        }
    }

    @MainActor
    @Test func recognizesOnlyAuthenticatedDiscordAppRoutes() throws {
        let accepted = [
            "https://discord.com/app",
            "https://discord.com/channels/@me",
            "https://canary.discord.com/channels/123/456",
        ]
        let rejected = [
            "https://discord.com/login",
            "https://discord.com/register",
            "https://discord.com/forgot-password",
            "https://support.discord.com/channels/@me",
            "https://example.com/channels/@me",
        ]

        for value in accepted {
            let url = try #require(URL(string: value))
            #expect(DiscordSessionCoordinator.isAuthenticatedAppURL(url))
        }
        for value in rejected {
            let url = try #require(URL(string: value))
            #expect(!DiscordSessionCoordinator.isAuthenticatedAppURL(url))
        }
    }
}
