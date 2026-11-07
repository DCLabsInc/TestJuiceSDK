import Foundation
import Testing
@testable import FeatureBerrySDK

@Suite struct WhatsNewAPITests {
    private let client = WhatsNewClient(
        apiKey: "client-key", appShortName: "Dog & Walk",
        baseURL: URL(string: "https://portal.featureberry.com")!)

    @Test func releaseRequestUsesHeaderAndEncodedCodeword() throws {
        let request = try client.releaseRequest(codeword: "release & 2")
        let components = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        #expect(components.path == "/api/sdk/v1/releases/whatsnew")
        #expect(components.queryItems == [URLQueryItem(name: "codeword", value: "release & 2")])
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "client-key")
        #expect(!components.queryItems!.contains { $0.name == "apiKey" })
    }

    #if canImport(UIKit) && canImport(ReplayKit)
    @Suite @MainActor struct WhatsNewSessionTests {
        @Test func sessionButtonRequiresMatchingReleaseConfiguration() {
            let manager = FeatureBerrySessionManager()
            #expect(!manager.isConfiguredForRelease(codeword: "v2"))
            manager.configure(apiKey: "client-key", testType: .feature, codeword: "v2", checklistItems: [])
            #expect(!manager.isConfiguredForRelease(codeword: "v2"))
            manager.configure(apiKey: "client-key", testType: .release, codeword: "v2", checklistItems: [])
            #expect(manager.isConfiguredForRelease(codeword: "v2"))
            #expect(!manager.isConfiguredForRelease(codeword: "v3"))
        }
    }
    #endif

    @Test func reviewsRequestUsesConfiguredAppAndHeader() throws {
        let request = try client.reviewsRequest()
        let components = try #require(request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)
        })
        #expect(components.path == "/api/sdk/v1/reviews/showcased")
        #expect(components.queryItems == [URLQueryItem(name: "appShortName", value: "Dog & Walk")])
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "client-key")
    }

    @Test func requestsRejectHttp() {
        let insecure = WhatsNewClient(
            apiKey: "client-key", appShortName: "Dog",
            baseURL: URL(string: "http://example.com")!)
        #expect(throws: FeatureBerryError.invalidURL) { try insecure.releaseRequest(codeword: "release") }
        #expect(throws: FeatureBerryError.invalidURL) { try insecure.reviewsRequest() }
    }

    @Test func decodesReleaseAndFiltersVisibleStatuses() throws {
        let data = Data(#"""
        {"releaseName":"Version 2","codeword":"v2","features":[
          {"title":"Ready","description":"Available","status":"Shipped"},
          {"title":"Beta","description":"Try it","status":"Testing"},
          {"title":"Later","description":"","status":"Future"}
        ]}
        """#.utf8)
        let release = try JSONDecoder().decode(WhatsNewRelease.self, from: data)
        #expect(release.releaseName == "Version 2")
        #expect(release.visibleFeatures.map(\.title) == ["Ready", "Beta"])
    }

    @Test func decodesShowcasedReviewsAndEmptyResults() throws {
        let data = Data(#"""
        {"appShortName":"Dog","reviews":[
          {"id":42,"title":"Great","author":"A","rating":5,"reviewText":"Nice",
           "developerReply":null,"submittedAt":"2026-11-05T14:30:00Z","repliedAt":null}
        ]}
        """#.utf8)
        let response = try JSONDecoder().decode(ShowcasedReviews.self, from: data)
        #expect(response.reviews.first?.id == 42)
        #expect(response.reviews.first?.rating == 5)
        let empty = try JSONDecoder().decode(
            ShowcasedReviews.self, from: Data(#"{"appShortName":"Dog","reviews":[]}"#.utf8))
        #expect(empty.reviews.isEmpty)
    }
}
