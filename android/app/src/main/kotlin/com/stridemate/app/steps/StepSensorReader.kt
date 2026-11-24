package com.stridemate.app.steps

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

/** Reads a single value from the hardware step counter (blocking, with timeout). */
object StepSensorReader {
    fun readOnce(context: Context, timeoutMs: Long = 5_000): Long? {
        val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val sensor = sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return null
        val latch = CountDownLatch(1)
        val value = AtomicLong(-1)
        val thread = HandlerThread("stridemate-step-read").apply { start() }
        val listener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                value.set(event.values[0].toLong())
                latch.countDown()
            }
            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        try {
            // maxReportLatencyUs = 0 asks the sensor hub to flush batched counts now.
            sm.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL, 0, Handler(thread.looper))
            sm.flush(listener)
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
        } finally {
            sm.unregisterListener(listener)
            thread.quitSafely()
        }
        return value.get().takeIf { it >= 0 }
    }

    /** Read and record. Returns steps newly counted, or null if no sensor/value. */
    fun sample(context: Context): Long? {
        val raw = readOnce(context) ?: return null
        return StepStore.get(context).record(context, raw).counted
    }
}
