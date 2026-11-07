import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WhatsNewRelease: Decodable, Sendable {
    struct Feature: Decodable, Sendable {
        let title: String
        let description: String
        let status: String
    }

    let releaseName: String
    let codeword: String?
    let features: [Feature]

    var visibleFeatures: [Feature] {
        features.filter { $0.status == "Shipped" || $0.status == "Testing" }
    }
}

struct ShowcasedReview: Decodable, Identifiable, Sendable {
    let id: Int
    let title: String
    let author: String
    let rating: Int
    let reviewText: String
}

struct ShowcasedReviews: Decodable, Sendable {
    let appShortName: String
    let reviews: [ShowcasedReview]
}

struct WhatsNewClient: Sendable {
    let apiKey: String
    let appShortName: String
    let baseURL: URL
    var session: URLSession = .shared

    func releaseRequest(codeword: String) throws -> URLRequest {
        try request(path: "/api/sdk/v1/releases/whatsnew",
                    query: URLQueryItem(name: "codeword", value: codeword))
    }

    func reviewsRequest() throws -> URLRequest {
        try request(path: "/api/sdk/v1/reviews/showcased",
                    query: URLQueryItem(name: "appShortName", value: appShortName))
    }

    func fetchRelease(codeword: String) async throws -> WhatsNewRelease {
        try await fetch(WhatsNewRelease.self, request: releaseRequest(codeword: codeword))
    }

    func fetchReviews() async throws -> [ShowcasedReview] {
        try await fetch(ShowcasedReviews.self, request: reviewsRequest()).reviews
    }

    private func request(path: String, query: URLQueryItem) throws -> URLRequest {
        guard baseURL.scheme?.lowercased() == "https",
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else { throw FeatureBerryError.invalidURL }
        components.path = path
        components.queryItems = [query]
        guard let url = components.url else { throw FeatureBerryError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<T: Decodable>(_ type: T.Type, request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw FeatureBerryError.make(statusCode: http.statusCode, responseBody: data)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
