package com.stridemate.app.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.app.PendingIntent
import android.widget.RemoteViews
import com.stridemate.app.MainActivity
import com.stridemate.app.R
import es.antonborri.home_widget.HomeWidgetProvider
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Home-screen widget. Flutter writes the de-duplicated total (all sources) via
 * home_widget; the native sampler writes the phone-only total when Flutter is not
 * running. The widget shows the larger of the two for today and a last-updated
 * time, flagged as stale after 2 hours.
 */
class StepWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences
    ) {
        val today = dayKey(System.currentTimeMillis())
        val appSteps = if (widgetData.getString("day", "") == today) widgetData.getInt("steps", 0).toLong() else 0L
        val appUpdated = widgetData.getLong("updated_ms", 0L)
        val phoneSteps = if (widgetData.getString("phone_day", "") == today) widgetData.getLong("phone_steps", 0L) else 0L
        val phoneUpdated = widgetData.getLong("phone_updated_ms", 0L)
        val steps = maxOf(appSteps, phoneSteps)
        val updated = maxOf(appUpdated, phoneUpdated)
        val goal = widgetData.getInt("goal", 8000).coerceAtLeast(1)
        val stale = updated == 0L || System.currentTimeMillis() - updated > 2 * 3_600_000L

        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.step_widget).apply {
                setTextViewText(R.id.widget_steps, String.format(Locale.getDefault(), "%,d", steps))
                setTextViewText(R.id.widget_goal, context.getString(R.string.widget_goal, String.format(Locale.getDefault(), "%,d", goal)))
                setProgressBar(R.id.widget_progress, goal, steps.coerceAtMost(goal.toLong()).toInt(), false)
                val time = if (updated == 0L) "—" else DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(updated))
                setTextViewText(
                    R.id.widget_updated,
                    if (stale) context.getString(R.string.widget_stale, time) else context.getString(R.string.widget_updated, time)
                )
                setOnClickPendingIntent(R.id.widget_root, open)
                setContentDescription(R.id.widget_root,
                    context.getString(R.string.widget_a11y, steps, goal, time))
            }
            appWidgetManager.updateAppWidget(id, views)
        }
    }

    companion object {
        private const val PREFS = "HomeWidgetPreferences" // shared with the home_widget plugin

        fun dayKey(ms: Long): String = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date(ms))

        fun pushPhoneSteps(context: Context, steps: Long, updatedMs: Long) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putLong("phone_steps", steps)
                .putString("phone_day", dayKey(updatedMs))
                .putLong("phone_updated_ms", updatedMs)
                .apply()
            refresh(context)
        }

        fun refresh(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(ComponentName(context, StepWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(context, StepWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                context.sendBroadcast(intent)
            }
        }
    }
}
