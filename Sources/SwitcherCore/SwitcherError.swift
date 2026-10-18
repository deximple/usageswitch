import Foundation

/// What happened to the previous state after a failed switch.
public enum RollbackOutcome: String, Codable, Equatable, Sendable {
    /// Files restored and Claude confirmed the previous account.
    case verified
    /// Files restored byte-identically; Claude's confirmation could not be observed.
    case unverified
    /// Restoring the previous files failed (the journal is kept for automatic recovery).
    case failed
}

public enum SwitcherError: Error, Equatable, CustomStringConvertible {
    case forbiddenWrite(String)
    case unknownAccount(String)
    case notEnrolled(label: String)
    case snapshotCorrupt(String)
    case snapshotIncompatible(String)
    case needsConfirmation(codeSessions: Int)
    case anotherSwitchInProgress
    case insufficientDisk(freeGB: Int, requiredGB: Int)
    case updateInProgress
    case updatePending
    case cannotSaveCurrentLogin
    case claudeNotInstalled
    case quitVetoed(waitedSeconds: Int)
    case quitTimeout(waitedSeconds: Int)
    case claudeStartedDuringSwap
    case swapFailed(String)
    case swapInterrupted
    case verificationFailed(String, rollback: RollbackOutcome)
    case activeIdentityUnknown(String)
    case enrollmentIdentityMismatch(expected: String, got: String)
    case io(String)
    case sqlite(String)
    case launchFailed(String)
    case cannotRemoveActive
    /// The personal 1.0 build left an unfinished switch; its own recovery must run first.
    case legacyRecoveryPending
    case invalidAccountName(maxLength: Int)
    case duplicateAccountName(String)
    case ambiguousAccount(String)
    case codexNotInstalled
    case codexCannotRemoveStandard
    case codexStillRunning(String)
    case codexSignInFailed(String)
    case codexSignInCancelled
    case codexCannotShow(String)
    case codexDefaultDataInUse
    case codexLaunchFailed(String)

    public var description: String {
        switch self {
        case .forbiddenWrite(let p): return L10n.t(.errForbiddenWrite, p)
        case .unknownAccount(let id): return L10n.t(.errUnknownAccount, id)
        case .notEnrolled(let l): return L10n.t(.errNotEnrolled, l)
        case .snapshotCorrupt(let r): return L10n.t(.errSnapshotCorrupt, r)
        case .snapshotIncompatible(let r): return L10n.t(.errSnapshotIncompatible, r)
        case .needsConfirmation(let n): return L10n.t(.errNeedsConfirmation, n)
        case .anotherSwitchInProgress: return L10n.t(.errSwitchInProgress)
        case .insufficientDisk(let f, let r): return L10n.t(.errInsufficientDisk, f, r)
        case .updateInProgress: return L10n.t(.errUpdateInProgress)
        case .updatePending: return L10n.t(.errUpdatePending)
        case .cannotSaveCurrentLogin: return L10n.t(.errCannotSaveCurrentLogin)
        case .claudeNotInstalled: return L10n.t(.errClaudeNotInstalled)
        case .quitVetoed(let s): return L10n.t(.errQuitVetoed, s)
        case .quitTimeout(let s): return L10n.t(.errQuitTimeout, s)
        case .claudeStartedDuringSwap: return L10n.t(.errClaudeStartedDuringSwap)
        case .swapFailed(let r): return L10n.t(.errSwapFailed, r)
        case .swapInterrupted: return L10n.t(.errSwapInterrupted)
        case .verificationFailed(let r, let rb):
            switch rb {
            case .verified: return L10n.t(.errVerifyFailedVerified, r)
            case .unverified: return L10n.t(.errVerifyFailedUnverified, r)
            case .failed: return L10n.t(.errVerifyFailedFailed, r)
            }
        case .activeIdentityUnknown(let r): return L10n.t(.errActiveUnknown, r)
        case .enrollmentIdentityMismatch(let e, let g): return L10n.t(.errEnrollmentMismatch, g, e)
        case .io(let r): return L10n.t(.errIO, r)
        case .sqlite(let r): return L10n.t(.errSQLite, r)
        case .launchFailed(let r): return L10n.t(.errLaunchFailed, r)
        case .cannotRemoveActive: return L10n.t(.errCannotRemoveActive)
        case .legacyRecoveryPending: return L10n.t(.errLegacyRecoveryPending)
        case .invalidAccountName(let max): return L10n.t(.errInvalidName, max)
        case .duplicateAccountName(let name): return L10n.t(.errDuplicateName, name)
        case .ambiguousAccount(let query): return L10n.t(.errAmbiguousAccount, query)
        case .codexNotInstalled: return L10n.t(.errCodexNotInstalled)
        case .codexCannotRemoveStandard: return L10n.t(.errCodexCannotRemoveStandard)
        case .codexStillRunning(let name): return L10n.t(.errCodexStillRunning, name)
        case .codexSignInFailed(let reason): return L10n.t(.errCodexSignInFailed, reason)
        case .codexSignInCancelled: return L10n.t(.errCodexSignInCancelled)
        case .codexCannotShow(let name): return L10n.t(.errCodexCannotShow, name)
        case .codexDefaultDataInUse: return L10n.t(.errCodexDefaultDataInUse)
        case .codexLaunchFailed(let reason): return L10n.t(.errCodexLaunchFailed, reason)
        }
    }

    /// Stable machine-readable code for the CLI's JSON output.
    public var code: String {
        switch self {
        case .forbiddenWrite: return "forbidden_write"
        case .unknownAccount: return "unknown_account"
        case .notEnrolled: return "not_enrolled"
        case .snapshotCorrupt: return "snapshot_corrupt"
        case .snapshotIncompatible: return "snapshot_incompatible"
        case .needsConfirmation: return "needs_confirmation"
        case .anotherSwitchInProgress: return "switch_in_progress"
        case .insufficientDisk: return "insufficient_disk"
        case .updateInProgress: return "update_in_progress"
        case .updatePending: return "update_pending"
        case .cannotSaveCurrentLogin: return "cannot_save_current_login"
        case .claudeNotInstalled: return "claude_not_installed"
        case .quitVetoed: return "quit_vetoed"
        case .quitTimeout: return "quit_timeout"
        case .claudeStartedDuringSwap: return "claude_started_during_swap"
        case .swapFailed: return "swap_failed"
        case .swapInterrupted: return "swap_interrupted"
        case .verificationFailed: return "verification_failed"
        case .activeIdentityUnknown: return "active_identity_unknown"
        case .enrollmentIdentityMismatch: return "enrollment_identity_mismatch"
        case .io: return "io"
        case .sqlite: return "sqlite"
        case .launchFailed: return "launch_failed"
        case .cannotRemoveActive: return "cannot_remove_active"
        case .legacyRecoveryPending: return "legacy_recovery_pending"
        case .invalidAccountName: return "invalid_name"
        case .duplicateAccountName: return "duplicate_name"
        case .ambiguousAccount: return "ambiguous_account"
        case .codexNotInstalled: return "codex_not_installed"
        case .codexCannotRemoveStandard: return "codex_cannot_remove_standard"
        case .codexStillRunning: return "codex_still_running"
        case .codexSignInFailed: return "codex_sign_in_failed"
        case .codexSignInCancelled: return "codex_sign_in_cancelled"
        case .codexCannotShow: return "codex_cannot_show"
        case .codexDefaultDataInUse: return "codex_default_data_in_use"
        case .codexLaunchFailed: return "codex_launch_failed"
        }
    }
}
