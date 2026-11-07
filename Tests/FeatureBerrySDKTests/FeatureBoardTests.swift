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
        #expect(components.queryItems?.first(where: { $0.name == "email" }) == nil)
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
        #expect(request.url?.path == "/api/sdk/v1/feature-suggestions")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "sdk-key")
        #expect(json["appShortName"] as? String == "StepDog")
        #expect(json["appId"] == nil)
        #expect(json["apiKey"] == nil)
        #expect(json["email"] as? String == "tester@example.com")
        #expect(json["featureName"] as? String == "Dark mode")
        #expect(json["description"] as? String == "Use a dark theme")
    }

    @Test func suggestionRequestOmitsEmptyOptionalDescription() throws {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))
        let request = try client.makeSuggestionRequest(FeatureBerryFeatureSuggestion(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            email: "tester@example.com",
            featureName: "Dark mode"))
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["description"] == nil)
    }

    @Test func voteRequestPostsCodewordAndEmailToV1Endpoint() throws {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))
        let request = try client.makeVoteRequest(email: "tester@example.com", codeword: "dark-mode")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/sdk/v1/feature-votes")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "sdk-key")
        #expect(json["codeword"] == "dark-mode")
        #expect(json["email"] == "tester@example.com")
    }

    @Test func voteRequestRejectsMissingCodeword() {
        let client = FeatureBoardClient(configuration: .init(
            appShortName: "StepDog",
            apiKey: "sdk-key",
            baseURL: URL(string: "https://portal.featureberry.com")!))

        #expect(throws: FeatureBerryError.invalidURL) {
            try client.makeVoteRequest(email: "tester@example.com", codeword: " \n")
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
            "codeword": "dark-mode",
            "hasVoted": true,
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
        #expect(response.features[0].codeword == "dark-mode")
        #expect(response.features[0].hasVoted)
        #expect(response.features[0].detailURL == "https://portal.featureberry.com/features/42")
        #expect(response.features[0].voteURL == "https://portal.featureberry.com/api/sdk/feature/42/vote")
        #expect(response.profileURL == "https://portal.featureberry.com/profile")
    }

    @Test func roadmapDecodesBuildBuggyResponse() throws {
        let json = """
        {
          "appId": 1,
          "appName": "StepDog",
          "profileUrl": "https://portal.featureberry.com/profile",
          "features": [{
            "id": 42,
            "title": "Share buttons",
            "description": "Share",
            "Codeword": "share-buttons",
            "priority": 2,
            "status": 2,
            "statusLabel": "Done",
            "horizon": 3,
            "voteCount": 5,
            "featureDetailURL": "https://portal.featureberry.com/feature/42",
            "profileURL": "https://portal.featureberry.com/profile"
          }]
        }
        """
        let response = try JSONDecoder().decode(FeatureBerryRoadmapResponse.self, from: Data(json.utf8))
        let feature = try #require(response.features.first)
        #expect(feature.status == "Done")
        #expect(feature.horizon == "Shipped")
        #expect(feature.isClosed)
        #expect(feature.codeword == "share-buttons")
        #expect(feature.detailURL == "https://portal.featureberry.com/feature/42")
        #expect(response.profileURL == "https://portal.featureberry.com/profile")
        #expect(feature.voteURL == nil)
    }

    @Test(arguments: [
        (0, "Future"), (1, "UpNext"), (2, "InProgress"), (3, "Shipped"), (4, "Testing")
    ])
    func roadmapDecodesNumericHorizons(value: Int, expected: String) throws {
        let json = #"{"id":1,"title":"Feature","status":0,"horizon":\#(value)}"#
        let feature = try JSONDecoder().decode(FeatureBerryRoadmapFeature.self, from: Data(json.utf8))
        #expect(feature.horizon == expected)
        #expect(feature.isClosed == (value == 3))
    }

    @Test func roadmapRejectsUnknownNumericStatus() {
        let json = #"{"id":1,"title":"Feature","status":9}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(FeatureBerryRoadmapFeature.self, from: Data(json.utf8))
        }
    }

    @Test func roadmapDecodesDirectLinksAndDoneWithoutHorizon() throws {
        let json = """
        {"features":[{"id":1,"title":"Feature","status":"Done","horizon":null,
        "featureDetailUrl":"/feature/1"}],"profileURL":"/profile"}
        """
        let response = try JSONDecoder().decode(FeatureBerryRoadmapResponse.self, from: Data(json.utf8))
        let feature = try #require(response.features.first)
        #expect(feature.isClosed)
        #expect(feature.detailURL == "/feature/1")
        #expect(response.profileURL == "/profile")
    }
}
