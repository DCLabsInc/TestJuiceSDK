import Foundation
import Testing
@testable import FeatureBerrySDK

@Suite struct FeatureBoardTests {
    @Test func roadmapRequestUsesAppShortNameAndApiKeyQueryParameters() throws {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "key & value",
            baseURL: URL(string: "https://portal.featureberry.com")!))

        let request = try client.makeFeaturesRequest()
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(request.httpMethod == "GET")
        #expect(components.path == "/api/sdk/roadmap/features")
        #expect(components.queryItems?.first(where: { $0.name == "appShortName" })?.value == "StepDog")
        #expect(components.queryItems?.first(where: { $0.name == "appId" }) == nil)
        #expect(components.queryItems?.first(where: { $0.name == "apiKey" })?.value == "key & value")
    }

    @Test func suggestionRequestEncodesRequiredPayload() throws {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))
        let request = try client.makeSuggestionRequest(FeatureBerryFeatureSuggestion(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            email: "tester@example.com",
            featureName: "Dark mode",
            description: "Use a dark theme"))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/sdk/feature/suggest")
        #expect(json["appShortName"] as? String == "StepDog")
        #expect(json["appId"] == nil)
        #expect(json["apiKey"] as? String == "sdk-key")
        #expect(json["email"] as? String == "tester@example.com")
        #expect(json["featureName"] as? String == "Dark mode")
        #expect(json["description"] as? String == "Use a dark theme")
    }

    @Test func voteRequestPostsEmailToApiProvidedUrl() throws {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))
        let voteURL = URL(string: "https://portal.featureberry.com/api/sdk/feature/42/vote")!
        let request = try client.makeVoteRequest(email: "tester@example.com", url: voteURL)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(request.httpMethod == "POST")
        #expect(request.url == voteURL)
        #expect(json["email"] == "tester@example.com")
    }

    @Test(arguments: [
        URL(string: "http://portal.featureberry.com/api/sdk/feature/42/vote")!,
        URL(string: "https://example.com/collect")!
    ])
    func voteRequestRejectsInsecureOrUntrustedUrls(url: URL) {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))

        #expect(throws: FeatureBerryError.invalidURL) {
            try client.makeVoteRequest(email: "tester@example.com", url: url)
        }
    }

    @Test func roadmapDecodesFeatureAndProfileLinks() throws {
        let json = """
        {
          "features": [{
            "id": 42,
            "title": "Dark mode",
            "description": "A dark theme",
            "status": "Backlog",
            "horizon": "UpNext",
            "priority": 2,
            "voteCount": 3,
            "links": {
              "FeatureDetail": "https://portal.featureberry.com/features/42",
              "Vote": "https://portal.featureberry.com/api/sdk/feature/42/vote"
            }
          }],
          "links": {"ProfileURL": "https://portal.featureberry.com/profile"}
        }
        """
        let response = try JSONDecoder().decode(FeatureBerryRoadmapResponse.self, from: Data(json.utf8))

        #expect(response.features.count == 1)
        #expect(response.features[0].title == "Dark mode")
        #expect(response.features[0].voteCount == 3)
        #expect(response.features[0].detailURL == "https://portal.featureberry.com/features/42")
        #expect(response.features[0].voteURL == "https://portal.featureberry.com/api/sdk/feature/42/vote")
        #expect(response.profileURL == "https://portal.featureberry.com/profile")
    }
}
