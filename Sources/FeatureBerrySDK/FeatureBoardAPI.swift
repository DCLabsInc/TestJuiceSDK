import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct FeatureBerryRoadmapFeature: Decodable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let description: String?
    public let status: String?
    public let horizon: String?
    public let priority: Int?
    public let voteCount: Int
    public let links: [String: String]

    public var detailURL: String? {
        Self.link(in: links, matching: ["FeatureDetail", "featureDetail", "detail", "details"])
    }

    public var voteURL: String? {
        Self.link(in: links, matching: ["Vote", "vote", "VoteURL", "voteURL"])
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case description
        case status
        case horizon
        case priority
        case voteCount
        case links
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        horizon = try container.decodeIfPresent(String.self, forKey: .horizon)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        links = try container.decodeIfPresent([String: String].self, forKey: .links) ?? [:]
    }

    fileprivate static func link(in links: [String: String], matching names: [String]) -> String? {
        for name in names {
            if let value = links[name], !value.isEmpty { return value }
        }
        return nil
    }
}

public struct FeatureBerryRoadmapResponse: Decodable, Sendable {
    public let features: [FeatureBerryRoadmapFeature]
    public let profileURL: String?

    private enum CodingKeys: String, CodingKey {
        case features
        case links
        case profileURL
        case ProfileURL
    }

    private struct Links: Decodable {
        let values: [String: String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            values = try container.decode([String: String].self)
        }
    }

    public init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            var decoded: [FeatureBerryRoadmapFeature] = []
            while !unkeyed.isAtEnd {
                decoded.append(try unkeyed.decode(FeatureBerryRoadmapFeature.self))
            }
            features = decoded
            profileURL = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        features = try container.decodeIfPresent([FeatureBerryRoadmapFeature].self, forKey: .features) ?? []
        let links = try container.decodeIfPresent(Links.self, forKey: .links)?.values ?? [:]
        profileURL = try container.decodeIfPresent(String.self, forKey: .profileURL)
            ?? container.decodeIfPresent(String.self, forKey: .ProfileURL)
            ?? FeatureBerryRoadmapFeature.link(in: links, matching: ["ProfileURL", "profileURL", "profile"])
            ?? features.first.flatMap {
                FeatureBerryRoadmapFeature.link(in: $0.links, matching: ["ProfileURL", "profileURL", "profile"])
            }
    }
}

public struct FeatureBerryFeatureSuggestion: Encodable, Sendable {
    public let appShortName: String
    public let apiKey: String
    public let email: String
    public let featureName: String
    public let description: String?

    public init(appShortName: String, apiKey: String, email: String, featureName: String, description: String? = nil) {
        self.appShortName = appShortName
        self.apiKey = apiKey
        self.email = email
        self.featureName = featureName
        self.description = description
    }
}

struct FeatureBoardConfiguration: Sendable {
    let appShortName: String
    let apiKey: String
    let baseURL: URL
}

struct FeatureBoardClient: Sendable {
    static let featuresPath = "/api/sdk/roadmap/features"
    static let suggestionPath = "/api/sdk/feature/suggest"
    private let configuration: FeatureBoardConfiguration
    private let session: URLSession

    init(configuration: FeatureBoardConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func makeFeaturesRequest() throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw FeatureBerryError.invalidURL
        }
        components.path = Self.featuresPath
        components.queryItems = [
            URLQueryItem(name: "appShortName", value: configuration.appShortName),
            URLQueryItem(name: "apiKey", value: configuration.apiKey)
        ]
        guard let url = components.url else { throw FeatureBerryError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func makeSuggestionRequest(_ suggestion: FeatureBerryFeatureSuggestion) throws -> URLRequest {
        guard let url = URL(string: Self.suggestionPath, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw FeatureBerryError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(suggestion)
        return request
    }

    func makeVoteRequest(email: String, url: URL) throws -> URLRequest {
        guard Self.isSecureAPIURL(url, baseURL: configuration.baseURL) else {
            throw FeatureBerryError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Vote(email: email))
        return request
    }

    func fetchFeatures() async throws -> FeatureBerryRoadmapResponse {
        let (data, response) = try await session.data(for: makeFeaturesRequest())
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(FeatureBerryRoadmapResponse.self, from: data)
    }

    func suggest(_ suggestion: FeatureBerryFeatureSuggestion) async throws {
        let (data, response) = try await session.data(for: makeSuggestionRequest(suggestion))
        try Self.validate(response: response, data: data)
    }

    func vote(email: String, url: URL) async throws {
        let (data, response) = try await session.data(for: makeVoteRequest(email: email, url: url))
        try Self.validate(response: response, data: data)
    }

    private struct Vote: Encodable {
        let email: String
    }

    private static func isSecureAPIURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              baseURL.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == baseURL.host?.lowercased()
        else { return false }
        return true
    }

    private static func validate(response: URLResponse, data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeatureBerryError.make(statusCode: http.statusCode, responseBody: data)
        }
    }
}
