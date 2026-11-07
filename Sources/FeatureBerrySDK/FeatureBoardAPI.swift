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
    public let codeword: String?
    public let hasVoted: Bool
    private let featureDetailURL: String?

    public var detailURL: String? {
        Self.link(in: links, matching: ["FeatureDetail", "featureDetail", "detail", "details"])
            ?? featureDetailURL
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
        case codeword
        case Codeword
        case hasVoted
        case statusLabel
        case featureDetailURL
        case featureDetailUrl
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        status = try Self.decodeStatus(container, key: .status, names: ["Backlog", "InProgress", "Done"])
            ?? container.decodeIfPresent(String.self, forKey: .statusLabel)
        horizon = try Self.decodeStatus(
            container, key: .horizon, names: ["Future", "UpNext", "InProgress", "Shipped", "Testing"])
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        voteCount = try container.decodeIfPresent(Int.self, forKey: .voteCount) ?? 0
        links = try container.decodeIfPresent([String: String].self, forKey: .links) ?? [:]
        codeword = try container.decodeIfPresent(String.self, forKey: .codeword)
            ?? container.decodeIfPresent(String.self, forKey: .Codeword)
        hasVoted = try container.decodeIfPresent(Bool.self, forKey: .hasVoted)
            ?? false
        featureDetailURL = try container.decodeIfPresent(String.self, forKey: .featureDetailURL)
            ?? container.decodeIfPresent(String.self, forKey: .featureDetailUrl)
    }

    private static func decodeStatus(
        _ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys, names: [String]
    ) throws -> String? {
        guard container.contains(key), try !container.decodeNil(forKey: key) else { return nil }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        let value = try container.decode(Int.self, forKey: key)
        guard names.indices.contains(value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Unknown \(key.stringValue) value: \(value)")
        }
        return names[value]
    }

    var isClosed: Bool {
        [status, horizon].compactMap { $0 }.contains {
            let value = $0.lowercased()
            return value == "done" || value.contains("closed") || value.contains("shipped")
        }
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
        case profileUrl
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
            ?? container.decodeIfPresent(String.self, forKey: .profileUrl)
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

    private enum CodingKeys: String, CodingKey {
        case appShortName
        case email
        case featureName
        case description
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appShortName, forKey: .appShortName)
        try container.encode(email, forKey: .email)
        try container.encode(featureName, forKey: .featureName)
        try container.encodeIfPresent(description, forKey: .description)
    }
}

struct FeatureBoardConfiguration: Sendable {
    let appShortName: String
    let apiKey: String
    let baseURL: URL
}

struct FeatureBoardClient: Sendable {
    static let featuresPath = "/api/sdk/roadmap/features"
    static let suggestionPath = "/api/sdk/v1/feature-suggestions"
    static let votesPath = "/api/sdk/v1/feature-votes"
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
        try makeV1PostRequest(path: Self.suggestionPath, body: JSONEncoder().encode(suggestion))
    }

    func makeVoteRequest(email: String, codeword: String) throws -> URLRequest {
        guard !codeword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FeatureBerryError.invalidURL
        }
        return try makeV1PostRequest(
            path: Self.votesPath,
            body: JSONEncoder().encode(Vote(codeword: codeword, email: email)))
    }

    private func makeV1PostRequest(path: String, body: Data) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false) else {
            throw FeatureBerryError.invalidURL
        }
        components.path = path
        components.query = nil
        guard let url = components.url else { throw FeatureBerryError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
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

    func vote(email: String, codeword: String) async throws {
        let (data, response) = try await session.data(for: makeVoteRequest(email: email, codeword: codeword))
        try Self.validate(response: response, data: data)
    }

    private struct Vote: Encodable {
        let codeword: String
        let email: String
    }

    private static func validate(response: URLResponse, data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeatureBerryError.make(statusCode: http.statusCode, responseBody: data)
        }
    }
}
