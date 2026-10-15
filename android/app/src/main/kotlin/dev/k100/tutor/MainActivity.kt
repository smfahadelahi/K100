package dev.k100.tutor

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The Android entry point.
 *
 * K100 does nearly all of its work in Dart; this activity exists for exactly two
 * reasons:
 *
 *  1. It is the host FlutterActivity the manifest points at.
 *  2. It answers a tiny method channel — `dev.k100.tutor/device` — with the runtime
 *     memory limits the learner's phone imposes. The 1.5B model needs roughly
 *     900 MB of free heap to run comfortably and about 1.4 GB to load without
 *     thrashing; knowing the real ceiling lets [LlmService] recommend the 1.5B or
 *     the 0.5B model instead of letting the user pick one that will be killed by
 *     the low-memory killer halfway through a sentence.
 *
 * Nothing else is overridden: no custom permission plumbing (the plugins handle
 * it), no audio session hacks (flutter_tts owns that), no lifecycle games.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.k100.tutor/device"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "memoryInfo" -> result.success(memoryInfo())
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Returns the numbers the model picker needs.
     *
     * `runtimeMaxMb` is the most the VM will ever hand this process — the figure
     * that actually decides whether a quantised 1.5B model fits. `lowRamDevice`
     * mirrors Android's own verdict on the hardware. `is64Bit` guards against a
     * 32-bit-only install, which cannot map the model at all.
     */
    private fun memoryInfo(): Map<String, Any> {
        val runtime = Runtime.getRuntime()
        val activityManager =
            getSystemService(ACTIVITY_SERVICE) as android.app.ActivityManager

        return mapOf(
            "runtimeMaxMb" to (runtime.maxMemory() / (1024L * 1024L)).toInt(),
            "heapUsedMb" to ((runtime.totalMemory() - runtime.freeMemory()) / (1024L * 1024L)).toInt(),
            "totalMemMb" to (activityManager.memoryClass),
            "largeHeapClassMb" to (activityManager.largeMemoryClass),
            "lowRamDevice" to activityManager.isLowRamDevice,
            "is64Bit" to android.os.Process.is64Bit(),
            "sdkInt" to android.os.Build.VERSION.SDK_INT,
            "cpuAbi" to android.os.Build.SUPPORTED_ABIS.firstOrNull().orEmpty()
        )
    }
}
