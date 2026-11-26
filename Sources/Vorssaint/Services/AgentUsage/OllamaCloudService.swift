// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Ollama Cloud's allowance and spend, kept apart from the log readers the way
/// the added Codex homes are: nothing on disk to watch, so a request on a timer
/// is the reading. Asks only while the AI section is on and Ollama Cloud is one
/// of the agents, at most every `OllamaCloud.freshness`, and backs off after a
/// failure so a wrong key costs one request, not one a minute.
final class OllamaCloudService: ObservableObject {
    static let shared = OllamaCloudService()

    /// Runs the two requests; replaced in tests.
    typealias Reader = (String, @escaping (Result<OllamaCloud.Snapshot, OllamaCloud.Failure>) -> Void) -> Void

    @Published private(set) var snapshot: OllamaCloud.Snapshot?
    @Published private(set) var failure: OllamaCloud.Failure?
    @Published private(set) var checking = false

    var hasKey: Bool { OllamaCloud.key() != nil }

    private let reader: Reader
    private var timer: Timer?
    private var inFlight = false
    private var attempted = Date.distantPast
    /// The wait after the last failure, counted again from zero once one ask
    /// succeeds.
    private var retryAfter: TimeInterval = 0

    init(reader: @escaping Reader = { key, completion in OllamaCloud.read(key: key, completion: completion) }) {
        self.reader = reader
        snapshot = OllamaCloud.cached()
    }

    /// Only while the AI section is on and Ollama Cloud is one of its agents.
    private var isEnabled: Bool {
        NotchAgentSupport.isEnabled() && NotchAgentSupport.providers().contains(.ollama) && hasKey
    }

    /// Follows the section's state and asks now when the reading is due.
    func synchronize() {
        guard isEnabled else {
            timer?.invalidate()
            timer = nil
            return
        }
        refreshIfDue()
    }

    /// Reads the page's own call: asks when the reading is older than the
    /// background wait, never more often than that.
    func pageDidAppear() {
        refreshIfDue()
    }

    /// The Settings check button: asks regardless of the wait after a failure.
    func refreshNow() {
        retryAfter = 0
        attempted = .distantPast
        // A key saved just now turns the service on without a preferences
        // round trip, so the check does not wait for the next one.
        if !isEnabled { startTimerIfNeeded(); return }
        ask()
    }

    /// A key was removed or replaced: the old reading belongs to it and goes.
    func forceSynchronize() {
        timer?.invalidate()
        timer = nil
        if !hasKey {
            snapshot = nil
            failure = nil
            OllamaCloud.clearCache()
            AgentUsageService.shared.forgetLimits(.ollama)
        }
        synchronize()
    }

    private func refreshIfDue() {
        guard !inFlight else { return }
        let wait = failure == nil ? OllamaCloud.freshness : retryAfter
        guard Date().timeIntervalSince(attempted) >= wait else { return }
        ask()
    }

    private func ask() {
        guard !inFlight, let key = OllamaCloud.key() else { return }
        inFlight = true
        checking = true
        attempted = Date()
        reader(key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.checking = false
                switch result {
                case .success(let snapshot):
                    self.failure = nil
                    self.retryAfter = 0
                    self.snapshot = snapshot
                    OllamaCloud.save(snapshot)
                    AgentUsageService.shared.noteLimits(snapshot.limits)
                case .failure(let failure):
                    self.failure = failure
                    self.retryAfter = failure == .rateLimited ? OllamaCloud.rateLimitRetry : OllamaCloud.retryInterval
                }
                self.startTimerIfNeeded()
            }
        }
    }

    /// A timer rather than a chain of waits: the section coming and going
    /// cancels it with the rest.
    private func startTimerIfNeeded() {
        guard isEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refreshIfDue() }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
