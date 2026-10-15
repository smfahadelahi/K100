import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/ui/screens/home_screen.dart';
import 'package:k100/ui/screens/setup_screen.dart';

/// K100 — an offline AI language speaking tutor.
///
/// Startup order matters and is deliberately explicit:
///
///  1. bindings;
///  2. crash-log hooks (so a release build on a stranger's phone still tells us
///     what went wrong);
///  3. system chrome — dark status bar, portrait, edge-to-edge;
///  4. `SharedPreferences`, awaited **before** `runApp` so the learner profile is
///     available synchronously on the very first frame;
///  5. `ProviderScope` with that instance injected.
///
/// Nothing here touches the network, the microphone, the audio engine or the
/// model file: all of that is owned by `VoicePipelineController` and only starts
/// when a screen asks for it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    Log.error(
      'Flutter error: ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );
  };

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    Log.error('Uncaught platform error', error, stack);
    // Swallow: a rendering error must never take a conversation down with it.
    return true;
  };

  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.edgeToEdge,
    overlays: SystemUiOverlay.values,
  );

  final SharedPreferences preferences = await SharedPreferences.getInstance();
  Log.info('${AppConfig.appName} ${AppConfig.version} starting · '
      'first run: ${!preferences.containsKey('k100_onboarded')}');

  runApp(
    ProviderScope(
      // No explicit type argument here on purpose: the element type of this list
      // is Riverpod's override class, whose name is not part of the API the app
      // needs to spell out. Inference is exact, and it survives a Riverpod bump.
      overrides: [
        // The one override the whole app depends on: without it, every provider
        // that reads a stored setting would have to be asynchronous.
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: const K100App(),
    ),
  );
}

/// Root widget. Two destinations, both driven by the persisted profile:
/// the onboarding wizard, or the practice hub.
class K100App extends ConsumerWidget {
  const K100App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final LearnerProfile profile = ref.watch(profileProvider);

    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      // The app is English-labelled but teaches any language; letting Android
      // supply per-language typography keeps CJK and Arabic rendering correct.
      builder: (BuildContext context, Widget? child) {
        final MediaQueryData media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            // Clamp text scaling: past ~1.3× the orb and the control row stop
            // fitting on a small phone, and the orb is the app.
            textScaler: media.textScaler.clamp(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.3,
            ),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260),
        child: profile.onboarded
            ? const HomeScreen(key: ValueKey<String>('home'))
            : const SetupScreen(key: ValueKey<String>('setup')),
      ),
    );
  }
}
