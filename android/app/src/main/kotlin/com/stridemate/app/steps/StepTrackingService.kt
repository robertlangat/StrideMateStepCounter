package com.stridemate.app.steps

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.stridemate.app.MainActivity
import com.stridemate.app.R
import com.stridemate.app.widget.StepWidgetProvider
import java.text.DateFormat
import java.util.Date

/**
 * Optional foreground service ("Live counting" in Settings). Keeps a step-counter
 * listener registered so the ongoing notification and widget stay current.
 * Not required for accuracy: the hardware counter keeps counting while the app is
 * closed and WorkManager samples it every ~15 minutes.
 */
class StepTrackingService : Service(), SensorEventListener {
    private var sensorManager: SensorManager? = null
    private var lastNotifyMs = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel(this)
        val notification = buildNotification(this, StepStore.get(this).todayLocal(), System.currentTimeMillis())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_HEALTH)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        sensorManager = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        sensorManager?.getDefaultSensor(Sensor.TYPE_STEP_COUNTER)?.let {
            // Batch up to 60 s in the sensor hub to save battery.
            sensorManager?.registerListener(this, it, SensorManager.SENSOR_DELAY_NORMAL, 60_000_000)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onSensorChanged(event: SensorEvent) {
        val store = StepStore.get(this)
        store.record(this, event.values[0].toLong())
        val now = System.currentTimeMillis()
        if (now - lastNotifyMs > 30_000) {
            lastNotifyMs = now
            val today = store.todayLocal()
            NotificationManagerCompatWrapper.notify(this, NOTIFICATION_ID, buildNotification(this, today, now))
            StepWidgetProvider.pushPhoneSteps(this, today, now)
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

    override fun onDestroy() {
        sensorManager?.unregisterListener(this)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "stridemate_live_steps"
        const val NOTIFICATION_ID = 4107

        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, StepTrackingService::class.java))
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, StepTrackingService::class.java))
        }

        fun createChannel(context: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = context.getSystemService(NotificationManager::class.java)
                val channel = NotificationChannel(
                    CHANNEL_ID, context.getString(R.string.live_channel_name), NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description = context.getString(R.string.live_channel_description)
                    setShowBadge(false)
                }
                nm.createNotificationChannel(channel)
            }
        }

        fun buildNotification(context: Context, steps: Long, updatedMs: Long): Notification {
            val goal = StepStore.get(context).dailyGoal()
            val open = PendingIntent.getActivity(
                context, 0, Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val time = DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(updatedMs))
            return NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_walk)
                .setContentTitle(context.getString(R.string.live_notification_title, String.format("%,d", steps)))
                .setContentText(context.getString(R.string.live_notification_text, String.format("%,d", goal), time))
                .setProgress(goal.toInt().coerceAtLeast(1), steps.coerceAtMost(goal).toInt(), false)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShowWhen(false)
                .setContentIntent(open)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                .build()
        }
    }
}

/** Avoids a hard dependency on POST_NOTIFICATIONS being granted (Android 13+). */
object NotificationManagerCompatWrapper {
    fun notify(context: Context, id: Int, notification: Notification) {
        try {
            androidx.core.app.NotificationManagerCompat.from(context).notify(id, notification)
        } catch (e: SecurityException) {
            // Notification permission revoked: keep counting silently.
        }
    }
}
