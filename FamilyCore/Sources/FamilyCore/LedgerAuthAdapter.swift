import Foundation

/// Synchronous, fail-closed bridge for UsageLedger. Obtain this adapter from the
/// issuing ParentalAuth; callers cannot construct it or register credentials.
/// It verifies the same instance-local capability registry as the actor.
public final class ParentalAuthLedgerAuthorizer: LedgerAdminAuthorizing, @unchecked Sendable {
    private let registry: ParentalAuthorizationRegistry

    init(registry: ParentalAuthorizationRegistry) {
        self.registry = registry
    }

    public func authorize(operation: LedgerAdminOperation, credential: Data) throws {
        let context: ParentalAuthContext
        switch operation {
        case .configureFamily: context = .configureRules
        case .upsertProfile: context = .manageProfiles
        case .selectViewers: context = .manageSession
        case .reanchorClock: context = .recovery
        case .temporaryOverride: context = .temporaryOverride
        }
        // In particular, switchProfile never grants broad selectViewers access.
        try registry.validate(credential: credential, for: context)
    }
}
