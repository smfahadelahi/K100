import 'package:flutter_test/flutter_test.dart';

import 'package:k100/models/chat_message.dart';
import 'package:k100/models/tutor_state.dart';

/// The anti-loop contract, pinned as executable tests.
///
/// The two forbidden edges are the whole reason this app does not talk to
/// itself. If a future change adds them back — say, to make turns feel
/// snappier — these tests fail before a learner ever hears the echo.
void main() {
  group('kAllowedTransitions', () {
    test('there is never a listening → speaking edge', () {
      expect(canTransition(TutorState.userListening, TutorState.aiSpeaking), isFalse);
    });

    test('the microphone can only be re-armed through idle', () {
      expect(canTransition(TutorState.aiSpeaking, TutorState.userListening), isFalse);
      expect(canTransition(TutorState.aiSpeaking, TutorState.idle), isTrue);
      expect(canTransition(TutorState.idle, TutorState.userListening), isTrue);
    });

    test('text-to-speech only starts after the recogniser has been stopped', () {
      expect(canTransition(TutorState.userListening, TutorState.aiThinking), isTrue);
      expect(canTransition(TutorState.aiThinking, TutorState.aiSpeaking), isTrue);
    });

    test('idle may speak directly, for replay only', () {
      expect(canTransition(TutorState.idle, TutorState.aiSpeaking), isTrue);
    });

    test('every state can get back to idle', () {
      for (final TutorState state in TutorState.values) {
        expect(
          canTransition(state, TutorState.idle) || state == TutorState.idle,
          isTrue,
          reason: '${state.name} has no path back to idle',
        );
      }
    });

    test('a state always "transitions" to itself', () {
      for (final TutorState state in TutorState.values) {
        expect(canTransition(state, state), isTrue);
      }
    });

    test('every state has an entry in the table', () {
      for (final TutorState state in TutorState.values) {
        expect(kAllowedTransitions.containsKey(state), isTrue,
            reason: '${state.name} is missing from the transition table');
      }
    });
  });

  group('microphone lock', () {
    test('is held while thinking and while speaking', () {
      expect(TutorState.aiThinking.locksMicrophone, isTrue);
      expect(TutorState.aiSpeaking.locksMicrophone, isTrue);
    });

    test('is released while idle and while listening', () {
      expect(TutorState.idle.locksMicrophone, isFalse);
      expect(TutorState.userListening.locksMicrophone, isFalse);
    });

    test('every state with the lock held is also "busy"', () {
      for (final TutorState state in TutorState.values) {
        if (state.locksMicrophone) expect(state.isBusy, isTrue);
      }
    });
  });

  group('TutorRuntimeState', () {
    test('cannot start listening without a model, a lock release and idle', () {
      const TutorRuntimeState idle = TutorRuntimeState(modelLoaded: true);
      expect(idle.canStartListening, isTrue);

      expect(idle.copyWith(modelLoaded: false).canStartListening, isFalse);
      expect(idle.copyWith(micLocked: true).canStartListening, isFalse);
      expect(idle.copyWith(state: TutorState.aiSpeaking).canStartListening, isFalse);
      expect(idle.copyWith(engineLoading: true).canStartListening, isFalse);
    });

    test('counts only learner turns that carry feedback', () {
      final TutorRuntimeState state = TutorRuntimeState(
        modelLoaded: true,
        turns: <ChatMessage>[
          ChatMessage(
            role: MessageRole.user,
            text: 'I goes to school',
            correction: 'I go to school',
            explanation: 'third person singular',
            score: 60,
            createdAt: DateTime.now(),
          ),
          ChatMessage(
            role: MessageRole.tutor,
            text: 'Nice try!',
            createdAt: DateTime.now(),
          ),
          ChatMessage(
            role: MessageRole.user,
            text: 'I go to school every day',
            createdAt: DateTime.now(),
          ),
        ],
      );

      expect(state.correctionsCount, 1);
      expect(state.turnCount, 0);
      expect(state.lastUserMessage?.text, 'I go to school every day');
      expect(state.lastTutorMessage?.text, 'Nice try!');
    });

    test('formats latency and score for the status bar', () {
      const TutorRuntimeState idle = TutorRuntimeState();
      expect(idle.latencyLabel, '—');
      expect(idle.scoreLabel, '—');

      final TutorRuntimeState slow =
          idle.copyWith(lastLatency: const Duration(milliseconds: 2450));
      expect(slow.latencyLabel, '2.5 s');

      final TutorRuntimeState quick =
          idle.copyWith(lastLatency: const Duration(milliseconds: 640));
      expect(quick.latencyLabel, '640 ms');
    });
  });
}
