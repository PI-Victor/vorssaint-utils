// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Ollama Cloud: the shape the API answers in, the allowance it maps to, and
/// what a key must look like before it is sent anywhere.
enum OllamaCloudTests {
    static func run(_ suite: TestSuite) {
        decoding(suite)
        limits(suite)
        keys(suite)
        endpoints(suite)
        live(suite)
    }

    /// The exact answers ollama.com gives, decoded by the app's own decoder:
    /// snake_case keys, an ISO period, and cached input inside input.
    private static func decoding(_ suite: TestSuite) {
        let balance = OllamaCloud.decodeBalance(Data("""
        {"included":{"balance_usd":58.48102,"allowance_usd":60,"period":{"from":"2026-11-26T00:28:13Z","until":"2026-12-26T00:28:13Z"}},"purchased":{"balance_usd":0}}
        """.utf8))
        let usage = OllamaCloud.decodeUsage(Data("""
        {"range":"7d","granularity":"day","totals":{"request_count":1112,"usage_usd":1.51898,
          "input_tokens":94247712,"cached_input_tokens":91965021,"output_tokens":721555,
          "groups":[{"model":"minimax-m3","request_count":164,"usage_usd":0.34941},
                    {"model":"deepseek-v4.1-flash:1017","request_count":772,"usage_usd":0.9295}]}}
        """.utf8))
        suite.expect(balance?.included?.allowanceUSD == 60 && balance?.included?.balanceUSD == 58.48102
                        && balance?.included?.period?.until != nil && usage?.totals?.requestCount == 1112
                        && usage?.totals?.cachedInputTokens == 91965021 && usage?.totals?.groups?.count == 2,
                     "the balance and usage answers decode as ollama.com writes them")
    }

    /// The window the limits card shows is the allowance's used share, and a
    /// renewal that has passed is a fresh allowance rather than a spent one.
    private static func limits(_ suite: TestSuite) {
        let renews = Date(timeIntervalSince1970: 1_796_000_000)
        let fresh = OllamaCloud.Snapshot(remainingUSD: 45, allowanceUSD: 60, renewsAt: renews, purchasedUSD: 0,
                                         spendUSD: 1.52, requests: 100, inputTokens: 1_000, cacheReadTokens: 900,
                                         outputTokens: 50, models: [], observedAt: Date(timeIntervalSince1970: 1_795_000_000))
        suite.expectClose(fresh.usedPercent, 25, "a quarter of the allowance spent")
        let window = fresh.limits.windows.first
        suite.expect(fresh.limits.provider == .ollama && window?.usedPercent == 25 && window?.resetsAt == renews
                        && fresh.limits.source == .account,
                     "the allowance maps to one account window that renews with the period")

        let noAllowance = OllamaCloud.Snapshot(remainingUSD: 0, allowanceUSD: 0, renewsAt: nil, purchasedUSD: 3,
                                               spendUSD: 0, requests: 0, inputTokens: 0, cacheReadTokens: 0,
                                               outputTokens: 0, models: [], observedAt: Date())
        suite.expect(noAllowance.limits.windows.isEmpty && noAllowance.usedPercent == 0,
                     "an account with no included credits has no window rather than a full one")

        // Ollama counts cached input inside its input, so the page's split must
        // not count it twice.
        suite.expect(fresh.tokens.input == 100 && fresh.tokens.cacheRead == 900 && fresh.tokens.output == 50,
                     "cached input is taken out of input, not added to it")
    }

    /// The query has to reach the endpoint as a query: a path component would
    /// encode its `?` and ollama.com would answer 404 for a valid key.
    /// A real reading, only when a key is offered: the two requests, their
    /// folding, and the saved shape. `VORSSAINT_OLLAMA_LIVE=1` plus
    /// `OLLAMA_API_KEY` in the environment opts in, so CI never calls out.
    private static func live(_ suite: TestSuite) {
        guard ProcessInfo.processInfo.environment["VORSSAINT_OLLAMA_LIVE"] == "1",
              let key = ProcessInfo.processInfo.environment["OLLAMA_API_KEY"], !key.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<OllamaCloud.Snapshot, OllamaCloud.Failure>?
        OllamaCloud.read(key: key) { result in
            outcome = result
            done.signal()
        }
        _ = done.wait(timeout: .now() + 40)
        switch outcome {
        case .success(let snapshot)?:
            suite.expect(snapshot.allowanceUSD >= 0 && snapshot.observedAt.timeIntervalSinceNow > -60
                            && snapshot.models.allSatisfy { !$0.model.isEmpty },
                         "a live reading of ollama.com folds into a snapshot")
            print("live: credits \(snapshot.remainingUSD)/\(snapshot.allowanceUSD), spend \(snapshot.spendUSD), "
                  + "\(snapshot.requests) requests, \(snapshot.models.count) models, renews \(String(describing: snapshot.renewsAt))")
        case .failure(let failure)?:
            suite.expect(false, "a live reading of ollama.com succeeds (\(failure))")
        case nil:
            suite.expect(false, "a live reading of ollama.com answers in time")
        }
    }

    private static func endpoints(_ suite: TestSuite) {
        let balance = OllamaCloud.endpointURL("balance")
        let usage = OllamaCloud.endpointURL("usage", query: [URLQueryItem(name: "range", value: "7d"),
                                                             URLQueryItem(name: "group_by", value: "model")])
        suite.expect(balance?.absoluteString == "https://ollama.com/api/balance"
                        && usage?.absoluteString == "https://ollama.com/api/usage?range=7d&group_by=model"
                        && usage?.query == "range=7d&group_by=model",
                     "the usage request keeps its query instead of encoding the question mark")
    }

    private static func keys(_ suite: TestSuite) {
        suite.expect(OllamaCloud.looksLikeKey("  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ")
                        && !OllamaCloud.looksLikeKey("") && !OllamaCloud.looksLikeKey("short")
                        && !OllamaCloud.looksLikeKey("aaaaaaaaaaaaaaaaaaaaaaaa has a space"),
                     "a key is accepted once it is long enough and holds no spaces")
    }
}
