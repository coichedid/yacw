import Foundation

/// Prepaid credit balance of the account, modeled on docs/samples/credits-response.example.json
/// (`balance.money.{amount_minor, currency, exponent}`; example: 2500 / USD / 2 = 25.00).
public struct CreditBalance: Equatable, Sendable {
    public var currency: String
    public var amount: Double
    public var fetchedAt: Date
    public init(currency: String, amount: Double, fetchedAt: Date) {
        self.currency = currency; self.amount = amount; self.fetchedAt = fetchedAt
    }
}

public enum CreditsDecoder {
    /// Anything that deviates from the sampled shape is `endpointChanged`, never a partial or guessed number.
    /// `tranches` (purchase history) exists in the sample and is deliberately not decoded.
    public static func decodeStrict(_ data: Data, fetchedAt: Date = Date()) throws -> CreditBalance {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.endpointChanged("resposta de créditos não é um objeto JSON")
        }
        guard let b = o["balance"] as? [String: Any], let m = b["money"] as? [String: Any] else {
            throw ProviderError.endpointChanged("balance.money ausente")
        }
        guard let minor = (m["amount_minor"] as? NSNumber)?.doubleValue, minor >= 0 else {
            throw ProviderError.endpointChanged("balance.money.amount_minor inválido")
        }
        guard let exp = (m["exponent"] as? NSNumber)?.intValue, (0...4).contains(exp) else {
            throw ProviderError.endpointChanged("balance.money.exponent inválido")
        }
        guard let cur = m["currency"] as? String, cur.count == 3 else {
            throw ProviderError.endpointChanged("balance.money.currency inválido")
        }
        return CreditBalance(currency: cur, amount: minor / pow(10, Double(exp)), fetchedAt: fetchedAt)
    }
}

public struct CreditsState: Equatable, Sendable {
    /// Last known balance; kept across failures so the UI never goes blank.
    public var balance: CreditBalance?
    /// Set when the latest attempt failed (the balance, if any, is then stale).
    public var failure: ProviderError?
    public init(balance: CreditBalance? = nil, failure: ProviderError? = nil) { self.balance = balance; self.failure = failure }
}

/// Queries the credits endpoint at most every `interval` (5 min), on demand when forced, and never twice within
/// `minGap` (30 s, the SPEC rule for remote calls). Failures keep the last balance.
public actor CreditsService {
    public static let interval: TimeInterval = 300
    public static let minGap: TimeInterval = 30
    private let transport: @Sendable () async throws -> Data
    private var lastAttempt: Date?
    public private(set) var state: CreditsState

    public init(initial: CreditBalance? = nil, transport: @escaping @Sendable () async throws -> Data) {
        self.transport = transport; self.state = CreditsState(balance: initial)
    }

    public func refresh(force: Bool, now: Date = Date()) async -> CreditsState {
        if let last = lastAttempt {
            let age = now.timeIntervalSince(last)
            if age < Self.minGap || (!force && age < Self.interval) { return state }
        }
        lastAttempt = now
        do {
            state = CreditsState(balance: try CreditsDecoder.decodeStrict(try await transport(), fetchedAt: now))
        } catch let e as ProviderError {
            state.failure = e
        } catch {
            state.failure = .offline
        }
        return state
    }

    /// Source C switched off or login finished: drop the failure and let the next call go out right away.
    public func reset() { lastAttempt = nil; state.failure = nil }
}
