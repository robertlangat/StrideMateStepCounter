package com.stridemate.app.steps

import android.content.Context
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.stridemate.app.widget.StepWidgetProvider
import java.util.concurrent.TimeUnit

/**
 * Samples the hardware counter about every 15 minutes (the WorkManager minimum).
 * Frequent samples shrink the window of steps lost if the phone reboots before the
 * next reading, and keep the widget fresh. Android may defer this in Doze / battery
 * saver or for apps in the "restricted" standby bucket.
 */
class StepSampleWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val ctx = applicationContext
        StepSensorReader.sample(ctx)
        val store = StepStore.get(ctx)
        StepWidgetProvider.pushPhoneSteps(ctx, store.todayLocal(), System.currentTimeMillis())
        store.prune(System.currentTimeMillis() - 400L * 24 * 3_600_000L)
        return Result.success()
    }

    companion object {
        private const val NAME = "stridemate-step-sample"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<StepSampleWorker>(15, TimeUnit.MINUTES).build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
