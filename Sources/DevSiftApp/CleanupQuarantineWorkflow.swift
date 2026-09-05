import DevSiftCore

protocol CleanupQuarantineWorkflowExecuting: Sendable {
  func execute(
    _ reviewSession: CleanupApprovalReviewSession
  ) async -> CleanupQuarantineWorkflowResult
}

enum CleanupQuarantineWorkflowResult: Equatable, Sendable {
  case execution(CleanupQuarantineFrontendExecutionResult)
  case failed(CleanupQuarantineWorkflowStageFailure)
}

enum CleanupQuarantineWorkflowStage: Equatable, Sendable {
  case reviewConfirmation
  case approval
  case authorizationAttempt
  case authorizationIssuance
}

enum CleanupQuarantineWorkflowStageFailure: Equatable, Sendable {
  case cancelled(CleanupQuarantineWorkflowStage)
  case rejected(CleanupQuarantineWorkflowStage)
  case failed(CleanupQuarantineWorkflowStage)
}

/// Converts one retained Core review session into one fresh quarantine attempt.
///
/// The caller must invoke this workflow only after the user explicitly accepts
/// the current npm-stopped statement. Each invocation constructs the exact
/// attempt-bound attestation requested by Core; no assertion is cached or
/// accepted as an input value.
struct CleanupQuarantineWorkflow: CleanupQuarantineWorkflowExecuting, Sendable {
  private let approver: any CleanupApproving
  private let authorizer: any CleanupQuarantineAuthorizing
  private let executor: any CleanupQuarantineFrontendExecuting

  init() {
    approver = CleanupApprover()
    authorizer = CleanupQuarantineAuthorizer()
    executor = CleanupQuarantineFrontendExecutor()
  }

  init(
    approver: any CleanupApproving,
    authorizer: any CleanupQuarantineAuthorizing,
    executor: any CleanupQuarantineFrontendExecuting
  ) {
    self.approver = approver
    self.authorizer = authorizer
    self.executor = executor
  }

  func execute(
    _ reviewSession: CleanupApprovalReviewSession
  ) async -> CleanupQuarantineWorkflowResult {
    let confirmations: [CleanupApprovalEntryConfirmation]
    let acknowledgements: [CleanupApprovalPreconditionReviewAcknowledgement]
    do {
      try Task.checkCancellation()
      confirmations = try reviewSession.entryReferences.map { reference in
        try Task.checkCancellation()
        return try reviewSession.confirm(reference)
      }
      acknowledgements = try reviewSession.preconditionReferences.map { reference in
        try Task.checkCancellation()
        return try reviewSession.acknowledgePreconditionForReview(reference)
      }
      try Task.checkCancellation()
    } catch is CancellationError {
      return .failed(.cancelled(.reviewConfirmation))
    } catch is CleanupApprovalError {
      return .failed(.rejected(.reviewConfirmation))
    } catch {
      return .failed(.failed(.reviewConfirmation))
    }

    let approval: CleanupApproval
    do {
      try Task.checkCancellation()
      approval = try approver.approve(
        CleanupApprovalRequest(
          session: reviewSession,
          confirmations: confirmations,
          preconditionReviewAcknowledgements: acknowledgements
        )
      )
      try Task.checkCancellation()
    } catch is CancellationError {
      return .failed(.cancelled(.approval))
    } catch is CleanupApprovalError {
      return .failed(.rejected(.approval))
    } catch {
      return .failed(.failed(.approval))
    }

    let authorizationSession: CleanupQuarantineAuthorizationSession
    do {
      try Task.checkCancellation()
      authorizationSession = try authorizer.beginAttempt(for: approval)
      try Task.checkCancellation()
    } catch is CancellationError {
      return .failed(.cancelled(.authorizationAttempt))
    } catch is CleanupQuarantineAuthorizationError {
      return .failed(.rejected(.authorizationAttempt))
    } catch {
      return .failed(.failed(.authorizationAttempt))
    }

    return await authorizeAndExecute(authorizationSession)
  }

  private func authorizeAndExecute(
    _ authorizationSession: CleanupQuarantineAuthorizationSession
  ) async -> CleanupQuarantineWorkflowResult {
    await withTaskCancellationHandler {
      do {
        try Task.checkCancellation()
        let request = authorizationSession.attestationRequest
        let attestation = CleanupQuarantineUserAttestation(
          request: request,
          statement: request.requiredStatement
        )
        let authorization = try await authorizationSession.authorize(using: attestation)
        try Task.checkCancellation()
        return .execution(await executor.execute(authorization))
      } catch is CancellationError {
        await authorizationSession.cancel()
        return .failed(.cancelled(.authorizationIssuance))
      } catch is CleanupQuarantineAuthorizationError {
        await authorizationSession.cancel()
        return .failed(.rejected(.authorizationIssuance))
      } catch {
        await authorizationSession.cancel()
        return .failed(.failed(.authorizationIssuance))
      }
    } onCancel: {
      Task {
        await authorizationSession.cancel()
      }
    }
  }
}
