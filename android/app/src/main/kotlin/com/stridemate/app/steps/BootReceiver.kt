package com.stridemate.app.steps

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlin.concurrent.thread

/**
 * - ACTION_SHUTDOWN: take a final reading so steps since the last sample are not
 *   lost when the counter resets on reboot (best effort: Android gives us ~seconds).
 * - BOOT_COMPLETED / MY_PACKAGE_REPLACED: re-baseline the counter, reschedule
 *   sampling and restart live counting if the user enabled it.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        thread(name = "stridemate-boot") {
            try {
                when (intent.action) {
                    Intent.ACTION_SHUTDOWN -> StepSensorReader.sample(context)
                    Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> {
                        StepSensorReader.sample(context)
                        StepSampleWorker.schedule(context)
                        if (StepStore.get(context).backgroundEnabled()) {
                            try {
                                StepTrackingService.start(context)
                            } catch (e: Exception) {
                                // Some OEMs/OS versions refuse FGS starts from boot; sampling still runs.
                            }
                        }
                    }
                }
            } finally {
                pending.finish()
            }
        }
    }
}
