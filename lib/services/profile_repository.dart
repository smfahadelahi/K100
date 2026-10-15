import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/models/language.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the learner profile in `shared_preferences`.
///
/// Why not SQLite? Because the profile is read **synchronously on startup** to
/// decide whether the onboarding wizard is needed, and `SharedPreferences` is the
/// only store on Android that can be loaded before `runApp` with a single await.
/// The heavier learning history lives in SQLite.
class ProfileRepository {
  ProfileRepository(this._prefs);

  final SharedPreferences _prefs;

  /// Reads the stored profile. Never throws: a corrupt or partially-written
  /// prefs store yields the defaults, because a learner locked out of their app
  /// by a bad boolean is a support nightmare.
  LearnerProfile load() {
    try {
      final Map<String, Object?> values = <String, Object?>{
        PrefKeys.onboarded: _prefs.getBool(PrefKeys.onboarded),
        PrefKeys.nativeLanguage: _prefs.getString(PrefKeys.nativeLanguage),
        PrefKeys.targetLanguage: _prefs.getString(PrefKeys.targetLanguage),
        PrefKeys.proficiency: _prefs.getString(PrefKeys.proficiency),
        PrefKeys.autoListen: _prefs.getBool(PrefKeys.autoListen),
        PrefKeys.showTranslations: _prefs.getBool(PrefKeys.showTranslations),
        PrefKeys.haptics: _prefs.getBool(PrefKeys.haptics),
        PrefKeys.ttsRate: _prefs.getDouble(PrefKeys.ttsRate),
        PrefKeys.ttsVoiceName: _prefs.getString(PrefKeys.ttsVoiceName),
        PrefKeys.dailyGoalMinutes: _prefs.getInt(PrefKeys.dailyGoalMinutes),
        PrefKeys.selectedModelId: _prefs.getString(PrefKeys.selectedModelId),
        PrefKeys.customModelUrl: _prefs.getString(PrefKeys.customModelUrl),
        PrefKeys.customModelName: _prefs.getString(PrefKeys.customModelName),
        'k100_sound_effects': _prefs.getBool('k100_sound_effects'),
        'k100_stt_on_device': _prefs.getBool('k100_stt_on_device'),
        'k100_streak': _prefs.getInt('k100_streak'),
        'k100_last_practice_day': _prefs.getString('k100_last_practice_day'),
      };

      return LearnerProfile.fromPreferences(
        fallbackNative: () => Languages.english,
        fallbackTarget: () => Languages.english,
        values: values,
      );
    } catch (error, stack) {
      Log.error('Could not read the learner profile — using defaults', error, stack);
      return LearnerProfile.defaults();
    }
  }

  /// Writes the whole profile. Only the keys that are actually set are written,
  /// so a `null` rate (meaning "follow the level") clears the override.
  Future<void> save(LearnerProfile profile) async {
    try {
      await _prefs.setBool(PrefKeys.onboarded, profile.onboarded);
      await _prefs.setString(PrefKeys.nativeLanguage, profile.nativeLanguage.code);
      await _prefs.setString(PrefKeys.targetLanguage, profile.targetLanguage.code);
      await _prefs.setString(PrefKeys.proficiency, profile.proficiency.name);
      await _prefs.setBool(PrefKeys.autoListen, profile.autoListen);
      await _prefs.setBool(PrefKeys.showTranslations, profile.showTranslations);
      await _prefs.setBool(PrefKeys.haptics, profile.haptics);
      await _prefs.setInt(PrefKeys.dailyGoalMinutes, profile.dailyGoalMinutes);
      await _prefs.setString(PrefKeys.selectedModelId, profile.selectedModelId);
      await _prefs.setBool('k100_sound_effects', profile.soundEffects);
      await _prefs.setBool('k100_stt_on_device', profile.sttOnDeviceOnly);
      await _prefs.setInt('k100_streak', profile.streakCount);

      final double? rate = profile.ttsRateOverride;
      if (rate == null) {
        await _prefs.remove(PrefKeys.ttsRate);
      } else {
        await _prefs.setDouble(PrefKeys.ttsRate, rate);
      }

      final String? voice = profile.ttsVoiceName;
      if (voice == null || voice.isEmpty) {
        await _prefs.remove(PrefKeys.ttsVoiceName);
      } else {
        await _prefs.setString(PrefKeys.ttsVoiceName, voice);
      }

      final String? customUrl = profile.customModelUrl;
      if (customUrl == null || customUrl.isEmpty) {
        await _prefs.remove(PrefKeys.customModelUrl);
      } else {
        await _prefs.setString(PrefKeys.customModelUrl, customUrl);
      }

      final String? customName = profile.customModelName;
      if (customName == null || customName.isEmpty) {
        await _prefs.remove(PrefKeys.customModelName);
      } else {
        await _prefs.setString(PrefKeys.customModelName, customName);
      }

      final String? lastDay = profile.lastPracticeDay;
      if (lastDay == null || lastDay.isEmpty) {
        await _prefs.remove('k100_last_practice_day');
      } else {
        await _prefs.setString('k100_last_practice_day', lastDay);
      }
    } catch (error, stack) {
      Log.error('Could not persist the learner profile', error, stack);
    }
  }

  /// Unlocks the UI after onboarding without touching anything else.
  Future<void> markOnboarded() async {
    try {
      await _prefs.setBool(PrefKeys.onboarded, true);
    } catch (error) {
      Log.error('Could not mark onboarding complete', error);
    }
  }

  /// Removes every preference this app owns.
  Future<void> wipe() async {
    try {
      for (final String key in PrefKeys.all) {
        await _prefs.remove(key);
      }
      Log.warn('Preferences wiped by the user');
    } catch (error, stack) {
      Log.error('Could not wipe preferences', error, stack);
    }
  }

  /// The raw store, exposed for the rare direct read (e.g. first-launch date).
  SharedPreferences get prefs => _prefs;
}
