import Foundation
import PasteoryCore

actor LinkResolutionService {
    private let repository: any ClipRepository
    private let session: URLSession
    private var inFlight = [String: Task<Void, Never>]()
    private let resolvedCacheLifetime: TimeInterval = 24 * 60 * 60
    private let failedRetryDelay: TimeInterval = 5 * 60
    private let maximumResponseBytes = 5 * 1024 * 1024

    init(repository: any ClipRepository) {
        self.repository = repository
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadRevalidatingCacheData
        self.session = URLSession(configuration: configuration)
    }

    func resolve(clip: Clip, allowNetwork: Bool = true, force: Bool = false) async {
        guard clip.primaryKind == .link,
              let url = URLFallbackEngine.normalizedWebURL(clip.previewText) else { return }
        let normalizedURL = url.absoluteString
        if let task = inFlight[normalizedURL] {
            await task.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.resolve(url: url, clipID: clip.id, allowNetwork: allowNetwork, force: force)
        }
        inFlight[normalizedURL] = task
        await task.value
        inFlight[normalizedURL] = nil
    }

    func retry(group: LinkFailureGroup) async {
        guard let resources = try? await repository.unresolvedLinkResources(routeKey: group.routeSignature.key) else { return }
        for resource in resources {
            guard let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) else { continue }
            await resolve(url: url, existing: resource, force: true)
        }
    }

    func retry(resource: LinkResource) async {
        guard let url = URLFallbackEngine.normalizedWebURL(resource.normalizedURL) else { return }
        await resolve(url: url, existing: resource, force: true)
    }

    func recordAuthenticatedResult(resource: LinkResource, snapshot: AuthenticatedPageSnapshot) async {
        let startedAt = Date().addingTimeInterval(-Double(snapshot.durationMilliseconds) / 1_000)
        let requestedURL = URL(string: resource.normalizedURL)
        guard let requestedURL else { return }
        let preliminary = LinkTitleQualityEvaluator.assess(
            candidates: snapshot.candidates,
            requestedURL: requestedURL,
            finalURL: snapshot.finalURL
        )
        let repetition: LinkTitleRepetitionStats
        if let fingerprint = preliminary.fingerprint {
            repetition = (try? await repository.linkTitleRepetitionStats(
                host: resource.host,
                routeKey: resource.routeSignature.key,
                fingerprint: fingerprint
            )) ?? LinkTitleRepetitionStats()
        } else {
            repetition = LinkTitleRepetitionStats()
        }
        let assessment = LinkTitleQualityEvaluator.assess(
            candidates: snapshot.candidates,
            requestedURL: requestedURL,
            finalURL: snapshot.finalURL,
            repetition: repetition
        )
        var updated = resource
        updated.candidateTitle = assessment.candidateTitle
        if assessment.quality.canReplaceFallback {
            updated.resolvedTitle = assessment.selectedTitle
        }
        updated.titleQuality = assessment.quality
        updated.requestState = Self.requestState(for: assessment)
        updated.resolutionSource = .webKit
        updated.updatedAt = Date()
        updated.lastAttemptAt = updated.updatedAt
        updated.attemptCount += 1
        if updated.requestState != .resolved { updated.failedAttemptCount += 1 }
        let attempt = LinkResolutionAttempt(
            linkResourceID: updated.id,
            startedAt: startedAt,
            finishedAt: updated.updatedAt,
            resolver: .webKit,
            requestState: updated.requestState,
            finalURL: snapshot.finalURL.absoluteString,
            candidateTitle: assessment.candidateTitle,
            candidateFingerprint: assessment.fingerprint,
            quality: assessment.quality,
            evidence: assessment.evidence,
            durationMilliseconds: snapshot.durationMilliseconds
        )
        try? await repository.saveLinkResolution(updated, attempt: attempt)
    }

    func recordAuthenticatedFailure(resource: LinkResource, errorCode: String) async {
        let startedAt = Date()
        var updated = resource
        updated.requestState = .networkError
        updated.titleQuality = .ambiguous
        updated.resolutionSource = .webKit
        updated.updatedAt = startedAt
        updated.lastAttemptAt = startedAt
        updated.attemptCount += 1
        updated.failedAttemptCount += 1
        let attempt = LinkResolutionAttempt(
            linkResourceID: updated.id,
            startedAt: startedAt,
            finishedAt: startedAt,
            resolver: .webKit,
            requestState: .networkError,
            quality: .ambiguous,
            durationMilliseconds: 0,
            errorCode: errorCode
        )
        try? await repository.saveLinkResolution(updated, attempt: attempt)
    }

    private func resolve(url: URL, clipID: UUID, allowNetwork: Bool, force: Bool) async {
        do {
            let rules = try await repository.userFallbackRules()
            let fallback = URLFallbackEngine.fallback(for: url, rules: rules)
            let proposed = LinkResource(
                normalizedURL: url.absoluteString,
                host: url.host?.lowercased() ?? "",
                routeSignature: fallback.routeSignature,
                fallbackTitle: fallback.title,
                fallbackState: fallback.state,
                matchedFallbackRuleID: fallback.matchedRuleID
            )
            let resource = try await repository.associateLink(clipID: clipID, resource: proposed)
            guard allowNetwork else { return }
            await resolve(url: url, existing: resource, force: force)
        } catch {
            // Clip persistence must remain successful even when enrichment storage fails.
        }
    }

    private func resolve(url: URL, existing resource: LinkResource, force: Bool) async {
        let now = Date()
        if !force, let lastAttempt = resource.lastAttemptAt {
            let minimumDelay = resource.requestState == .resolved ? resolvedCacheLifetime : failedRetryDelay
            if now.timeIntervalSince(lastAttempt) < minimumDelay { return }
        }

        let startedAt = Date()
        guard Self.isAllowed(url) else {
            await persistFailure(
                resource: resource,
                startedAt: startedAt,
                state: .blockedByPolicy,
                quality: .ambiguous,
                errorCode: "url_blocked_by_policy"
            )
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.6", forHTTPHeaderField: "Accept-Language")
        request.setValue(LinkWebKitConfiguration.compatibilityUserAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                await persistFailure(resource: resource, startedAt: startedAt, state: .networkError, quality: .ambiguous, errorCode: "non_http_response")
                return
            }
            let finalURL = response.url ?? url
            let statusState = Self.requestState(forHTTPStatus: response.statusCode)
            guard statusState == nil else {
                await persistFailure(
                    resource: resource,
                    startedAt: startedAt,
                    state: statusState!,
                    quality: statusState == .needsAuthentication ? .loginOrError : .ambiguous,
                    httpStatus: response.statusCode,
                    finalURL: finalURL,
                    errorCode: "http_\(response.statusCode)"
                )
                return
            }
            if Self.isVerificationChallenge(finalURL) {
                await persistFailure(
                    resource: resource,
                    startedAt: startedAt,
                    state: .verificationRequired,
                    quality: .loginOrError,
                    httpStatus: response.statusCode,
                    finalURL: finalURL,
                    errorCode: "verification_challenge"
                )
                return
            }
            guard data.count <= maximumResponseBytes else {
                await persistFailure(
                    resource: resource,
                    startedAt: startedAt,
                    state: .parserError,
                    quality: .ambiguous,
                    httpStatus: response.statusCode,
                    finalURL: finalURL,
                    errorCode: "response_too_large"
                )
                return
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard contentType.isEmpty || contentType.contains("html") || contentType.contains("xhtml") else {
                await persistFailure(
                    resource: resource,
                    startedAt: startedAt,
                    state: .missingTitle,
                    quality: .ambiguous,
                    httpStatus: response.statusCode,
                    finalURL: finalURL,
                    errorCode: "unsupported_content_type"
                )
                return
            }

            let candidates = HTMLTitleExtractor.candidates(from: data)
            let preliminary = LinkTitleQualityEvaluator.assess(
                candidates: candidates,
                requestedURL: url,
                finalURL: finalURL
            )
            let repetition: LinkTitleRepetitionStats
            if let fingerprint = preliminary.fingerprint {
                repetition = (try? await repository.linkTitleRepetitionStats(
                    host: resource.host,
                    routeKey: resource.routeSignature.key,
                    fingerprint: fingerprint
                )) ?? LinkTitleRepetitionStats()
            } else {
                repetition = LinkTitleRepetitionStats()
            }
            let assessment = LinkTitleQualityEvaluator.assess(
                candidates: candidates,
                requestedURL: url,
                finalURL: finalURL,
                repetition: repetition
            )
            var updated = resource
            updated.candidateTitle = assessment.candidateTitle
            if assessment.quality.canReplaceFallback {
                updated.resolvedTitle = assessment.selectedTitle
            }
            updated.titleQuality = assessment.quality
            updated.requestState = Self.requestState(for: assessment)
            updated.resolutionSource = .anonymousHTTP
            updated.updatedAt = Date()
            updated.lastAttemptAt = updated.updatedAt
            updated.attemptCount += 1
            if updated.requestState != .resolved { updated.failedAttemptCount += 1 }
            let attempt = LinkResolutionAttempt(
                linkResourceID: updated.id,
                startedAt: startedAt,
                finishedAt: updated.updatedAt,
                resolver: .anonymousHTTP,
                requestState: updated.requestState,
                httpStatus: response.statusCode,
                finalURL: finalURL.absoluteString,
                candidateTitle: assessment.candidateTitle,
                candidateFingerprint: assessment.fingerprint,
                quality: assessment.quality,
                evidence: assessment.evidence,
                durationMilliseconds: Self.durationMilliseconds(since: startedAt)
            )
            try await repository.saveLinkResolution(updated, attempt: attempt)
        } catch let error as URLError {
            let state: LinkRequestState = error.code == .timedOut ? .timeout : .networkError
            await persistFailure(
                resource: resource,
                startedAt: startedAt,
                state: state,
                quality: .ambiguous,
                errorCode: "url_error_\(error.code.rawValue)"
            )
        } catch {
            await persistFailure(
                resource: resource,
                startedAt: startedAt,
                state: .parserError,
                quality: .ambiguous,
                errorCode: "unexpected_error"
            )
        }
    }

    private func persistFailure(
        resource: LinkResource,
        startedAt: Date,
        state: LinkRequestState,
        quality: LinkTitleQuality,
        httpStatus: Int? = nil,
        finalURL: URL? = nil,
        errorCode: String
    ) async {
        var updated = resource
        updated.requestState = state
        updated.titleQuality = quality
        updated.resolutionSource = .anonymousHTTP
        updated.updatedAt = Date()
        updated.lastAttemptAt = updated.updatedAt
        updated.attemptCount += 1
        updated.failedAttemptCount += 1
        let attempt = LinkResolutionAttempt(
            linkResourceID: updated.id,
            startedAt: startedAt,
            finishedAt: updated.updatedAt,
            resolver: .anonymousHTTP,
            requestState: state,
            httpStatus: httpStatus,
            finalURL: finalURL?.absoluteString,
            quality: quality,
            durationMilliseconds: Self.durationMilliseconds(since: startedAt),
            errorCode: errorCode
        )
        try? await repository.saveLinkResolution(updated, attempt: attempt)
    }

    private static func requestState(for assessment: LinkTitleAssessment) -> LinkRequestState {
        switch assessment.quality {
        case .verified, .distinctive, .identifierOnly: .resolved
        case .generic: .genericTitle
        case .loginOrError: .needsAuthentication
        case .ambiguous: assessment.candidateTitle == nil ? .missingTitle : .parserError
        }
    }

    private static func requestState(forHTTPStatus status: Int) -> LinkRequestState? {
        switch status {
        case 200..<300: nil
        case 401: .needsAuthentication
        case 403: .forbidden
        case 404: .notFound
        case 408, 504: .timeout
        default: .networkError
        }
    }

    private static func isVerificationChallenge(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "mp.weixin.qq.com" && path.contains("appmsgcaptcha")
    }

    private static func durationMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }

    private static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "0.0.0.0" || host == "::1" { return false }
        if isPrivateIPv4(host) { return false }
        let riskySegments = Set(["logout", "signout", "delete", "unsubscribe", "accept-invite", "confirm-delete"])
        let pathSegments = url.path.lowercased().split(separator: "/").map(String.init)
        return riskySegments.isDisjoint(with: pathSegments)
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ 0...255 ~= $0 }) else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 169, parts[1] == 254 { return true }
        return false
    }
}
