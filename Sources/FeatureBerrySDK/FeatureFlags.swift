import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
#endif

public enum FeatureBerryHorizon: String, Decodable, Equatable, Sendable {
    case future = "Future"
    case upNext = "UpNext"
    case inProgress = "InProgress"
    case testing = "Testing"
    case shipped = "Shipped"
}

public struct FeatureBerryAppFeature: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let codeword: String

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case codeword
    }

    public init(id: Int, title: String, codeword: String) {
        self.id = id
        self.title = title
        self.codeword = codeword
    }
}

struct FeatureBerryHorizonResponse: Decodable {
    let horizon: FeatureBerryHorizon

    private enum CodingKeys: String, CodingKey {
        case horizon
        case status
    }

    init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(FeatureBerryHorizon.self) {
            horizon = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        horizon = try container.decodeIfPresent(FeatureBerryHorizon.self, forKey: .horizon)
            ?? container.decode(FeatureBerryHorizon.self, forKey: .status)
    }
}

struct FeatureBerryAppFeaturesResponse: Decodable {
    let features: [FeatureBerryAppFeature]

    private enum CodingKeys: String, CodingKey {
        case features
    }

    init(from decoder: Decoder) throws {
        if let values = try? decoder.singleValueContainer().decode([FeatureBerryAppFeature].self) {
            features = values
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            features = try container.decode([FeatureBerryAppFeature].self, forKey: .features)
        }
    }
}

struct FeatureBerryFeatureClient: Sendable {
    let apiKey: String
    let appShortName: String
    let baseURL: URL
    private let session: URLSession

    init(
        apiKey: String,
        appShortName: String,
        baseURL: URL = FeatureBerryConfiguration.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.appShortName = appShortName
        self.baseURL = baseURL
        self.session = session
    }

    func makeHorizonRequest(codeword: String) throws -> URLRequest {
        try makeRequest(path: "/api/sdk/feature/horizon", query: [
            URLQueryItem(name: "codeword", value: codeword),
            URLQueryItem(name: "apiKey", value: apiKey)
        ])
    }

    func makeFeaturesRequest() throws -> URLRequest {
        try makeRequest(path: "/api/sdk/app/features", query: [
            URLQueryItem(name: "appShortName", value: appShortName),
            URLQueryItem(name: "apiKey", value: apiKey)
        ])
    }

    func fetchHorizon(codeword: String) async throws -> FeatureBerryHorizon {
        let (data, response) = try await session.data(for: makeHorizonRequest(codeword: codeword))
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(FeatureBerryHorizonResponse.self, from: data).horizon
    }

    func fetchFeatures() async throws -> [FeatureBerryAppFeature] {
        let (data, response) = try await session.data(for: makeFeaturesRequest())
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(FeatureBerryAppFeaturesResponse.self, from: data).features
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw FeatureBerryError.invalidURL
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FeatureBerryError.invalidURL
        }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw FeatureBerryError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func validate(response: URLResponse, data: Data) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FeatureBerryError.make(statusCode: http.statusCode, responseBody: data)
        }
    }
}

@MainActor
public enum FeatureBerry {
    private struct CachedHorizon {
        let value: FeatureBerryHorizon
        let fetchedAt: Date
    }

    private struct CachedFeatures {
        let value: [FeatureBerryAppFeature]
        let fetchedAt: Date
    }

    public static let horizonCacheDuration: TimeInterval = 7 * 60
    public static let featuresCacheDuration: TimeInterval = 12 * 60

    private static var client: FeatureBerryFeatureClient?
    private static var horizons: [String: CachedHorizon] = [:]
    private static var pendingHorizonRequests = Set<String>()
    private static var features: CachedFeatures?
    private static var backgroundObserver: NSObjectProtocol?
    /// Called on the main actor when the user's testing mode changes.
    public static var onUserIsTestingChanged: ((Bool) -> Void)?

    /// Whether the user has opted in to testing features for this app session.
    public static var userIsTesting = false {
        didSet {
            if userIsTesting != oldValue {
                onUserIsTestingChanged?(userIsTesting)
            }
        }
    }

    public static var isTestingSessionEnabled: Bool { userIsTesting }

    /// Configure feature flags with the app's SDK API key and FeatureBerry short name.
    /// Feature statuses are fetched as needed and cached for seven minutes.
    public static func configure(
        apiKey: String,
        appShortName: String,
        baseURL: URL = FeatureBerryConfiguration.defaultBaseURL
    ) {
        horizons.removeAll()
        pendingHorizonRequests.removeAll()
        features = nil
        userIsTesting = false
        client = FeatureBerryFeatureClient(apiKey: apiKey, appShortName: appShortName, baseURL: baseURL)
        observeBackgrounding()
        Task { try? await refreshFeatures() }
    }

    /// Returns a synchronous flag handle. A status not yet cached is fetched in the background
    /// and evaluates to `false` until that request completes.
    public static func Feature(_ codeword: String) -> FeatureBerryFeatureFlag {
        FeatureBerryFeatureFlag(codeword: codeword)
    }

    /// Fetches the app's feature list, using its 12-minute cache unless forced.
    @discardableResult
    public static func refreshFeatures(force: Bool = false) async throws -> [FeatureBerryAppFeature] {
        if !force, let features, Date().timeIntervalSince(features.fetchedAt) < featuresCacheDuration {
            return features.value
        }
        guard let client else { throw FeatureBerryError.featureFlagsNotConfigured }
        let values = try await client.fetchFeatures()
        features = CachedFeatures(value: values, fetchedAt: Date())
        return values
    }

    /// Fetches a feature's current Horizon status, using its seven-minute cache unless forced.
    @discardableResult
    public static func refreshFeature(codeword: String, force: Bool = false) async throws -> FeatureBerryHorizon {
        if !force, let cached = validHorizon(for: codeword) {
            return cached
        }
        guard let client else { throw FeatureBerryError.featureFlagsNotConfigured }
        let value = try await client.fetchHorizon(codeword: codeword)
        horizons[codeword] = CachedHorizon(value: value, fetchedAt: Date())
        return value
    }

    static func cachedHorizon(for codeword: String) -> FeatureBerryHorizon? {
        guard let value = validHorizon(for: codeword) else {
            guard client != nil, pendingHorizonRequests.insert(codeword).inserted else { return nil }
            Task {
                defer { pendingHorizonRequests.remove(codeword) }
                _ = try? await refreshFeature(codeword: codeword)
            }
            return nil
        }
        return value
    }

    private static func validHorizon(for codeword: String) -> FeatureBerryHorizon? {
        guard let cached = horizons[codeword],
              Date().timeIntervalSince(cached.fetchedAt) < horizonCacheDuration
        else { return nil }
        return cached.value
    }

    static func cacheHorizon(_ horizon: FeatureBerryHorizon, for codeword: String, fetchedAt: Date = Date()) {
        horizons[codeword] = CachedHorizon(value: horizon, fetchedAt: fetchedAt)
    }

    private static func observeBackgrounding() {
        #if canImport(UIKit)
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in userIsTesting = false }
        }
        #endif
    }
}

@MainActor
public struct FeatureBerryFeatureFlag {
    public let codeword: String

    public var Live: Bool {
        FeatureBerry.cachedHorizon(for: codeword) == .shipped
    }

    public var Testing: Bool {
        FeatureBerry.cachedHorizon(for: codeword) == .testing
    }

    public var LiveOrUserIsTesting: Bool {
        let horizon = FeatureBerry.cachedHorizon(for: codeword)
        return horizon == .shipped || (horizon == .testing && FeatureBerry.userIsTesting)
    }
}

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public struct FeatureBerryTestingSettings: View {
    private let title: String
    private let tint: Color

    public init(title: String = "Test new features", tint: Color = .accentColor) {
        self.title = title
        self.tint = tint
    }

    public var body: some View {
        Button(title) {
            FeatureBerry.userIsTesting = true
        }
        .tint(tint)
    }
}
#endif
