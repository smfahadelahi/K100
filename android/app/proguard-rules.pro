# K100 R8 rules.
#
# R8 is disabled in `build.gradle` by default (see the comment there). These rules
# exist so that flipping `minifyEnabled true` / `shrinkResources true` after a
# device test is a safe, one-line change.
#
# Everything below is reflective or reachable only through a platform channel, so
# R8 cannot prove it is used.

# ─── Flutter embedding ────────────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-keep class io.flutter.embedding.** { *; }

# ─── llama.cpp engine (fcllama) ───────────────────────────────────────────────
# The engine runs in a bound Service and talks over named EventChannels, so the
# class names are looked up by string at runtime.
-keep class ink.xcl.fllama.** { *; }
-keep class dev.k100.tutor.** { *; }
-keep interface ink.xcl.fllama.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
-keep class * extends android.app.Service

# ─── speech_to_text ───────────────────────────────────────────────────────────
-keep class com.csdcorp.speech_to_text.** { *; }

# ─── flutter_tts ──────────────────────────────────────────────────────────────
-keep class com.eyedeadevelopment.fluttertts.** { *; }

# ─── permission_handler ───────────────────────────────────────────────────────
-keep class com.baseflow.permissionhandler.** { *; }

# ─── sqflite / path_provider / shared_preferences ─────────────────────────────
-keep class com.tekartik.sqflite.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# ─── dio / crypto (no reflection in these, but keep the stack traces readable) ─
-dontwarn okio.**
-dontwarn com.squareup.okhttp3.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**

# Keep annotations used by kotlinx / androidx.
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod
-keepattributes SourceFile,LineNumberTable
