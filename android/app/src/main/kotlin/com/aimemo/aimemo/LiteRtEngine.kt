package com.aimemo.aimemo

import android.content.Context
import android.util.Log
import com.google.ai.edge.litertlm.*
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Native LiteRT-LM inference engine for on-device LLM.
 *
 * Uses Google AI Edge LiteRT-LM to run Gemma 4 E2B/E4B
 * directly on the device without internet connection.
 */
class LiteRtEngine(private val context: Context) {

    companion object {
        private const val TAG = "LiteRtEngine"
    }

    private var engine: Engine? = null
    private var isInitialized = false

    /** Write crash-safe marker to file (survives process death).
     *  Truncates to last 50 lines when file exceeds 50KB. */
    private fun crashMarker(msg: String) {
        val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US).format(Date())
        try {
            val f = File(context.filesDir, "litert_diag.txt")
            if (f.exists() && f.length() > 50 * 1024) {
                val lines = f.readLines()
                val tail = if (lines.size > 50) lines.drop(lines.size - 50) else lines
                f.writeText(tail.joinToString("\n") + "\n")
            }
            f.appendText("[$ts] $msg\n")
        } catch (_: Exception) {}
    }

    fun isAvailable(): Boolean {
        return try {
            android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Initialize engine with a downloaded model file.
     * Timeout after 120 seconds to prevent hanging.
     * Writes crash markers before each critical step for post-mortem analysis.
     */
    fun initEngine(modelPath: String): Boolean {
        crashMarker("=== initEngine START ===")
        return try {
            val modelFile = File(modelPath)
            if (!modelFile.exists() || modelFile.length() == 0L) {
                crashMarker("FAIL: model file not found: $modelPath")
                Log.e(TAG, "Model file not found or empty: $modelPath")
                isInitialized = false
                return false
            }

            crashMarker("model OK: ${modelFile.length()} bytes")
            Log.i(TAG, "modelPath=$modelPath size=${modelFile.length()} bytes")

            runBlocking(Dispatchers.IO) {
                try {
                    crashMarker("Creating EngineConfig (GPU, maxNumTokens=2048)...")
                    val engineConfig = EngineConfig(
                        modelPath = modelPath,
                        backend = Backend.GPU(),
                        cacheDir = context.cacheDir.path,
                        maxNumTokens = 2048,
                    )
                    crashMarker("Creating Engine instance (GPU)...")
                    engine = Engine(engineConfig)
                    crashMarker("Calling engine.initialize() on GPU...")
                    withTimeout(120_000L) {
                        engine!!.initialize()
                    }
                    crashMarker("engine.initialize() on GPU completed OK")
                } catch (gpuError: Throwable) {
                    crashMarker("GPU init failed: ${gpuError.message}. Falling back to CPU...")
                    Log.w(TAG, "GPU initialization failed, falling back to CPU", gpuError)
                    engine?.close()

                    crashMarker("Creating EngineConfig (CPU fallback, maxNumTokens=2048)...")
                    val engineConfig = EngineConfig(
                        modelPath = modelPath,
                        backend = Backend.CPU(),
                        cacheDir = context.cacheDir.path,
                        maxNumTokens = 2048,
                    )
                    crashMarker("Creating Engine instance (CPU fallback)...")
                    engine = Engine(engineConfig)
                    crashMarker("Calling engine.initialize() on CPU fallback... (may crash if OOM)")
                    withTimeout(120_000L) {
                        engine!!.initialize()
                    }
                    crashMarker("engine.initialize() on CPU fallback completed OK")
                }
            }

            isInitialized = true
            crashMarker("=== initEngine SUCCESS ===")
            Log.i(TAG, "=== initEngine SUCCESS ===")
            true
        } catch (e: Throwable) {
            crashMarker("!!! initEngine FAILED: ${e.message} (${e.javaClass.simpleName})")
            Log.e(TAG, "=== initEngine FAILED: ${e.message} (${e.javaClass.simpleName}) ===")
            engine?.close()
            engine = null
            isInitialized = false
            false
        }
    }

    /**
     * Generate text from a prompt using the loaded model.
     * Timeout after 90 seconds to prevent hanging.
     */
    fun generate(prompt: String, maxTokens: Int = 1500, temperature: Double = 0.2): String? {
        if (!isInitialized || engine == null) {
            crashMarker("generate SKIP: engine not initialized")
            Log.w(TAG, "generate() called but engine not initialized")
            return null
        }

        crashMarker("=== generate START ===")
        return try {
            Log.i(TAG, "prompt.length=${prompt.length} maxTokens=$maxTokens temperature=$temperature")

            val result = runBlocking(Dispatchers.IO) {
                crashMarker("Creating Session...")
                val session = withTimeout(30_000L) {
                    engine!!.createSession()
                }
                crashMarker("Session created OK")
                try {
                    crashMarker("Starting runPrefill...")
                    withTimeout(30_000L) {
                        session.runPrefill(listOf(InputData.Text(prompt)))
                    }
                    crashMarker("runPrefill done, starting runDecode...")
                    val response = withTimeout(90_000L) {
                        session.runDecode()
                    }
                    val text = response.trim()
                    crashMarker("Generation done: ${text.length} chars")
                    text
                } finally {
                    session.close()
                    crashMarker("Session closed")
                }
            }

            crashMarker("=== generate SUCCESS: ${result.length} chars ===")
            Log.i(TAG, "=== generate SUCCESS: ${result.length} chars ===")
            result
        } catch (e: Throwable) {
            crashMarker("!!! generate FAILED: ${e.message} (${e.javaClass.simpleName})")
            Log.e(TAG, "=== generate FAILED: ${e.message} (${e.javaClass.simpleName}) ===")
            null
        }
    }

    fun close() {
        try {
            crashMarker("Closing engine")
            engine?.close()
            engine = null
            isInitialized = false
        } catch (_: Exception) {}
    }
}
