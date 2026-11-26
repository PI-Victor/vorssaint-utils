// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Ollama Cloud's side of the account: the included credit allowance, the
/// 7-day spend and the token totals behind it, read from ollama.com with the
/// person's API key. Ollama keeps no session log on this Mac, so these two
/// requests are the whole reading.
///
/// Nothing but the key ever leaves the Mac, and the key is kept where no other
/// account can read it.
enum OllamaCloud {
    static let base = URL(string: "https://ollama.com/api")!
    /// The window the spend card covers. One range keeps the request count low:
    /// ollama.com allows ten requests a minute and a reading makes two.
    static let range = "7d"
    static let fileName = "ollama-cloud.json"

    /// A reading older than this is asked again in the background.
    static let freshness: TimeInterval = 10 * 60
    /// After a failure, the next attempt waits this long.
    static let retryInterval: TimeInterval = 5 * 60
    /// The API answers 429 above ten requests a minute.
    static let rateLimitRetry: TimeInterval = 70

    // MARK: Key

    private static var keyURL: URL? {
        PrivateFileStore.containerURL?.appendingPathComponent("ollama-api-key", isDirectory: false)
    }

    /// The saved key, or nil while none is. Kept in the app's private folder,
    /// owner-only, rather than the Keychain: the app is ad-hoc signed, so a
    /// Keychain item would belong to a signature that changes with each build
    /// and be asked about, or lost, on every update.
    static func key() -> String? {
        guard let url = keyURL, let data = try? Data(contentsOf: url),
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    static func save(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let container = PrivateFileStore.containerURL, let url = keyURL,
              PrivateFileStore.createDirectory(at: container) else { return false }
        return PrivateFileStore.write(Data(trimmed.utf8), to: url)
    }

    static func forgetKey() {
        guard let url = keyURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether a key looks like one before it is sent: ollama.com issues 32+
    /// characters without spaces.
    static func looksLikeKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 20 && !trimmed.contains(where: \.isWhitespace)
    }

    // MARK: Reading

    struct Snapshot: Codable, Equatable {
        /// Included credits left and the allowance they count against.
        var remainingUSD: Double
        var allowanceUSD: Double
        /// When the included allowance renews.
        var renewsAt: Date?
        /// Purchased credits, which never expire.
        var purchasedUSD: Double
        /// Totals over `range`.
        var spendUSD: Double
        var requests: Int
        var inputTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
        var models: [ModelSpend]
        var observedAt: Date

        struct ModelSpend: Codable, Equatable, Identifiable {
            var model: String
            var spendUSD: Double
            var requests: Int
            var id: String { model }
        }

        /// How much of the included allowance is spent, as the limits card
        /// shows every other agent's window.
        var usedPercent: Double {
            guard allowanceUSD > 0 else { return 0 }
            return min(100, max(0, (1 - remainingUSD / allowanceUSD) * 100))
        }

        var limits: AgentLimits {
            AgentLimits(provider: .ollama,
                        windows: allowanceUSD > 0
                            ? [AgentLimitWindow(id: "ollama:credits", kind: .other, minutes: nil, scope: nil,
                                                usedPercent: usedPercent, resetsAt: renewsAt)]
                            : [],
                        observedAt: observedAt, source: .account)
        }

        /// Token counts in the shape the rest of the page counts in. Ollama's
        /// cached input is a subset of its input, and it reports no cache
        /// writes and no separate reasoning tokens.
        var tokens: AgentTokens {
            AgentTokens(input: max(0, inputTokens - cacheReadTokens), cacheWrite: 0,
                        cacheRead: cacheReadTokens, output: outputTokens, reasoning: 0)
        }
    }

    enum Failure: Error, Equatable {
        /// ollama.com refused the key.
        case invalidKey
        case rateLimited
        case offline
        /// Anything else the API answered; the status is kept for Settings.
        case server(Int)
    }

    /// `path` is relative to `base`; a query goes in `query`, since a path
    /// component would encode its `?` and reach a different endpoint.
    static func endpointURL(_ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        return components?.url
    }

    private static func request(_ path: String, query: [URLQueryItem] = [], key: String) -> URLRequest {
        var request = URLRequest(url: endpointURL(path, query: query)!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("Vorssaint/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// The two answers, decoded by the app's own decoder so a test can hold
    /// the shape ollama.com actually writes.
    static func decodeBalance(_ data: Data) -> Balance? { try? decoder.decode(Balance.self, from: data) }
    static func decodeUsage(_ data: Data) -> Usage? { try? decoder.decode(Usage.self, from: data) }

    /// The API writes snake_case, and `USD` is an acronym no camel-case
    /// strategy spells back, so every key is named.
    struct Balance: Decodable {
        struct Included: Decodable {
            struct Period: Decodable {
                var until: Date?
            }
            var allowanceUSD: Double?
            var balanceUSD: Double?
            var period: Period?

            private enum CodingKeys: String, CodingKey {
                case allowanceUSD = "allowance_usd"
                case balanceUSD = "balance_usd"
                case period
            }
        }
        struct Purchased: Decodable {
            var balanceUSD: Double?

            private enum CodingKeys: String, CodingKey {
                case balanceUSD = "balance_usd"
            }
        }
        var included: Included?
        var purchased: Purchased?
    }

    struct Usage: Decodable {
        struct Totals: Decodable {
            struct Group: Decodable {
                var model: String?
                var usageUSD: Double?
                var requestCount: Int?

                private enum CodingKeys: String, CodingKey {
                    case model
                    case usageUSD = "usage_usd"
                    case requestCount = "request_count"
                }
            }
            var requestCount: Int?
            var usageUSD: Double?
            var inputTokens: Int?
            var cachedInputTokens: Int?
            var outputTokens: Int?
            var groups: [Group]?

            private enum CodingKeys: String, CodingKey {
                case requestCount = "request_count"
                case usageUSD = "usage_usd"
                case inputTokens = "input_tokens"
                case cachedInputTokens = "cached_input_tokens"
                case outputTokens = "output_tokens"
                case groups
            }
        }
        var totals: Totals?
    }

    /// Reads both endpoints and folds them into one snapshot. Requests run
    /// together; the completion arrives on a background queue.
    static func read(key: String, completion: @escaping (Result<Snapshot, Failure>) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var balance: Balance?
        var usage: Usage?
        var failure: Failure?

        func finish(_ error: Failure) {
            lock.withLock { if failure == nil { failure = error } }
        }

        group.enter()
        session.dataTask(with: request("balance", key: key)) { data, response, error in
            defer { group.leave() }
            if let error = error as? URLError, error.code == .notConnectedToInternet || error.code == .cannotConnectToHost {
                finish(.offline)
                return
            }
            guard let response = response as? HTTPURLResponse, let data else { finish(.offline); return }
            switch response.statusCode {
            case 200: break
            case 401, 403: finish(.invalidKey); return
            case 429: finish(.rateLimited); return
            default: finish(.server(response.statusCode)); return
            }
            if let decoded = try? decoder.decode(Balance.self, from: data) { lock.withLock { balance = decoded } }
            else { finish(.server(response.statusCode)) }
        }.resume()

        group.enter()
        let usageQuery = [URLQueryItem(name: "range", value: range), URLQueryItem(name: "group_by", value: "model")]
        session.dataTask(with: request("usage", query: usageQuery, key: key)) { data, response, error in
            defer { group.leave() }
            if let error = error as? URLError, error.code == .notConnectedToInternet || error.code == .cannotConnectToHost {
                finish(.offline)
                return
            }
            guard let response = response as? HTTPURLResponse, let data else { finish(.offline); return }
            switch response.statusCode {
            case 200: break
            case 401, 403: finish(.invalidKey); return
            case 429: finish(.rateLimited); return
            default: finish(.server(response.statusCode)); return
            }
            if let decoded = try? decoder.decode(Usage.self, from: data) { lock.withLock { usage = decoded } }
            else { finish(.server(response.statusCode)) }
        }.resume()

        group.notify(queue: .global(qos: .utility)) {
            if let failure = lock.withLock({ failure }) { completion(.failure(failure)); return }
            let (readBalance, readUsage) = lock.withLock { (balance, usage) }
            guard let readBalance, let readUsage else { completion(.failure(.server(0))); return }
            completion(.success(snapshot(balance: readBalance, usage: readUsage, now: Date())))
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func snapshot(balance: Balance, usage: Usage, now: Date) -> Snapshot {
        let totals = usage.totals
        let renews = balance.included?.period?.until
        // An allowance that already renewed while the reading was in flight is
        // spent from zero, not from what the previous period used.
        let renewed = renews.map { $0 <= now } ?? false
        let allowance = max(0, balance.included?.allowanceUSD ?? 0)
        let remaining = renewed ? allowance : max(0, balance.included?.balanceUSD ?? 0)
        var models = (totals?.groups ?? []).compactMap { group -> Snapshot.ModelSpend? in
            guard let model = group.model, !model.isEmpty else { return nil }
            return Snapshot.ModelSpend(model: model, spendUSD: group.usageUSD ?? 0, requests: group.requestCount ?? 0)
        }
        models.sort { $0.spendUSD > $1.spendUSD }
        return Snapshot(remainingUSD: remaining,
                        allowanceUSD: allowance,
                        renewsAt: renews,
                        purchasedUSD: max(0, balance.purchased?.balanceUSD ?? 0),
                        spendUSD: totals?.usageUSD ?? 0,
                        requests: totals?.requestCount ?? 0,
                        inputTokens: totals?.inputTokens ?? 0,
                        cacheReadTokens: totals?.cachedInputTokens ?? 0,
                        outputTokens: totals?.outputTokens ?? 0,
                        models: models,
                        observedAt: now)
    }

    /// The last reading, kept so the card shows something after a launch
    /// before the first request answers.
    static func cached() -> Snapshot? {
        guard let container = PrivateFileStore.containerURL, let data = try? Data(contentsOf: container.appendingPathComponent(fileName)) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    /// The reading belonged to a key that is gone.
    static func clearCache() {
        guard let container = PrivateFileStore.containerURL else { return }
        try? FileManager.default.removeItem(at: container.appendingPathComponent(fileName))
    }

    static func save(_ snapshot: Snapshot) {
        guard let container = PrivateFileStore.containerURL, PrivateFileStore.createDirectory(at: container),
              let data = try? encoder.encode(snapshot) else { return }
        PrivateFileStore.write(data, to: container.appendingPathComponent(fileName))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
