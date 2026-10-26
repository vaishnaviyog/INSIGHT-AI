import '../../models/adaptive_risk/adaptive_risk_assessment.dart';
import '../../models/adaptive_risk/adaptive_risk_input.dart';
import '../../models/adaptive_risk/navigation_decision.dart';
import '../../models/risk_assessment.dart';
import 'warning_prioritizer.dart';

/// The single entry point every navigation decision in INSIGHT is
/// meant to pass through, per this phase's explicit requirement.
/// Combines the Adaptive Risk Engine's assessment with the prioritized/
/// merged hazard warning and the current transit/voice state, and
/// resolves them into ONE discrete action — never lets a lower-
/// priority concern (e.g. "prepare for transfer") override a genuine
/// safety concern (an immediate-danger hazard), by checking in a
/// fixed, documented precedence order rather than a weighted blend
/// (a discrete action needs a decision, not an average).
///
/// PRECEDENCE ORDER (highest first):
///   1. Immediate-danger hazard -> stop immediately, always interrupts.
///   2. Overall risk level critical -> slow down, interrupts.
///   3. Awaiting voice confirmation of destination -> confirm destination.
///   4. Transit-phase actions (boarding / transferring) -> boardBus / prepareForTransfer.
///   5. High-urgency (but not immediate) hazard -> slow down.
///   6. Otherwise -> continue walking.
///
/// `moveLeft`/`moveRight`/`wait`/`repeatInstruction` are real, valid
/// outputs of this engine's action space but are only reachable from
/// call sites that supply the extra signal they need (a hazard's
/// [HorizontalPosition] for move-left/right, an explicit repeat
/// request for repeatInstruction) — this class exposes dedicated
/// methods for those rather than inferring them from the general
/// `decide()` path, since guessing a left/right correction from
/// ambiguous signals would be worse than not deciding at all.
class NavigationDecisionEngine {
  NavigationDecisionResult decide({
    required AdaptiveRiskAssessment risk,
    required PrioritizedWarning warning,
    required TransitPhase transitPhase,
    required bool awaitingVoiceConfirmation,
  }) {
    if (warning.urgency == WarningUrgency.immediate) {
      final message = warning.mergedMessage.isEmpty ? 'Stop.' : 'Stop. ${warning.mergedMessage}.';
      return NavigationDecisionResult(
        decision: NavigationDecision.stopImmediately,
        message: message,
        interrupt: true,
        reason: 'Immediate-danger hazard: ${warning.mergedMessage}',
      );
    }

    if (risk.riskLevel == RiskLevel.critical) {
      return NavigationDecisionResult(
        decision: NavigationDecision.slowDown,
        message: warning.mergedMessage.isEmpty
            ? 'Slow down, conditions are risky right now.'
            : 'Slow down. ${warning.mergedMessage}.',
        interrupt: true,
        reason: 'Overall adaptive risk score is critical (${risk.overallRiskScore.toStringAsFixed(2)}): '
            '${risk.explanation}',
      );
    }

    if (awaitingVoiceConfirmation) {
      return const NavigationDecisionResult(
        decision: NavigationDecision.confirmDestination,
        message: 'Please confirm your destination.',
        interrupt: false,
        reason: 'Voice Understanding Layer flagged a low-confidence destination resolution.',
      );
    }

    if (transitPhase == TransitPhase.boarding) {
      return const NavigationDecisionResult(
        decision: NavigationDecision.boardBus,
        message: 'You may board now.',
        interrupt: false,
        reason: 'Transit phase is boarding, with no immediate hazard.',
      );
    }
    if (transitPhase == TransitPhase.transferring) {
      return const NavigationDecisionResult(
        decision: NavigationDecision.prepareForTransfer,
        message: 'Prepare to transfer.',
        interrupt: false,
        reason: 'Transit phase is transferring.',
      );
    }

    if (warning.urgency == WarningUrgency.high) {
      return NavigationDecisionResult(
        decision: NavigationDecision.slowDown,
        message: warning.mergedMessage,
        interrupt: false,
        reason: 'High-urgency hazard nearby, but not immediate danger.',
      );
    }

    return const NavigationDecisionResult(
      decision: NavigationDecision.continueWalking,
      message: '',
      interrupt: false,
      reason: 'No significant risk or hazard currently present.',
    );
  }

  /// Dedicated method — see class doc comment on why this isn't
  /// folded into [decide]'s general path.
  NavigationDecisionResult decideLateralCorrection({required bool hazardOnLeft, required String hazardLabel}) {
    return NavigationDecisionResult(
      decision: hazardOnLeft ? NavigationDecision.moveRight : NavigationDecision.moveLeft,
      message: hazardOnLeft
          ? 'Move slightly right to avoid the $hazardLabel.'
          : 'Move slightly left to avoid the $hazardLabel.',
      interrupt: false,
      reason: '$hazardLabel detected on the ${hazardOnLeft ? 'left' : 'right'} side of frame.',
    );
  }

  NavigationDecisionResult decideRepeatInstruction() => const NavigationDecisionResult(
        decision: NavigationDecision.repeatInstruction,
        message: '',
        interrupt: false,
        reason: 'User explicitly requested the last instruction be repeated.',
      );

  NavigationDecisionResult decideWait(String reason) => NavigationDecisionResult(
        decision: NavigationDecision.wait,
        message: 'Please wait.',
        interrupt: false,
        reason: reason,
      );

  NavigationDecisionResult decideRequestUserConfirmation(String promptMessage, String reason) =>
      NavigationDecisionResult(
        decision: NavigationDecision.requestUserConfirmation,
        message: promptMessage,
        interrupt: false,
        reason: reason,
      );
}
