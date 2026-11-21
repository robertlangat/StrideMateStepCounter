package com.stridemate.app

import android.content.Intent
import android.os.Bundle
import com.stridemate.app.steps.StepSampleWorker
import com.stridemate.app.steps.StepSensorReader
import com.stridemate.app.steps.StepStore
import com.stridemate.app.steps.StepTrackingService
import com.stridemate.app.widget.StepWidgetProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * FlutterFragmentActivity is required by the health plugin (Health Connect
 * permission contract). The "stridemate/steps" channel exposes the native
 * step counter; heavy work runs off the main thread.
 */
class MainActivity : FlutterFragmentActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingLink = intent?.dataString
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.dataString?.let { link -> channel?.invokeMethod("onLink", link) }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "stridemate/steps")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            val ctx = applicationContext
            when (call.method) {
                "isStepCounterAvailable" -> result.success(StepStore.isSensorAvailable(ctx))
                "sampleNow" -> io.execute {
                    val counted = try { StepSensorReader.sample(ctx) } catch (e: SecurityException) { null }
                    runOnUiThread { result.success(counted) }
                }
                "getHourly" -> {
                    val from = (call.argument<Number>("fromMs") ?: 0).toLong()
                    val to = (call.argument<Number>("toMs") ?: Long.MAX_VALUE).toLong()
                    io.execute {
                        val rows = StepStore.get(ctx).hourly(from, to)
                        runOnUiThread { result.success(rows) }
                    }
                }
                "diagnostics" -> io.execute {
                    val d = StepStore.get(ctx).diagnostics(ctx)
                    runOnUiThread { result.success(d) }
                }
                "scheduleSampling" -> {
                    StepSampleWorker.schedule(ctx)
                    result.success(true)
                }
                "setLiveCounting" -> {
                    val on = call.argument<Boolean>("enabled") ?: false
                    StepStore.get(ctx).setBackgroundEnabled(on)
                    try {
                        if (on) StepTrackingService.start(ctx) else StepTrackingService.stop(ctx)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("service_start_failed", e.message, null)
                    }
                }
                "setDailyGoal" -> {
                    StepStore.get(ctx).setDailyGoal((call.argument<Number>("goal") ?: 8000).toLong())
                    result.success(true)
                }
                "refreshWidget" -> {
                    StepWidgetProvider.refresh(ctx)
                    result.success(true)
                }
                "getInitialLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                else -> result.notImplemented()
            }
        }
    }
}
