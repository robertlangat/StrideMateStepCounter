package com.stridemate.app.steps

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import java.util.Calendar
import java.util.TimeZone

/**
 * On-device store for phone-sensor hour buckets plus the counter state.
 * Lives outside Flutter so the background service, WorkManager job and boot /
 * shutdown receivers can record steps while the Flutter engine is not running.
 */
class StepStore private constructor(context: Context) :
    SQLiteOpenHelper(context.applicationContext, "phone_steps.db", null, 1) {

    private val prefs = context.applicationContext.getSharedPreferences("stridemate_counter", Context.MODE_PRIVATE)

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE hourly (hour_ms INTEGER PRIMARY KEY, steps INTEGER NOT NULL, updated_ms INTEGER NOT NULL)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    @Synchronized
    fun record(context: Context, raw: Long): StepCounterLogic.Result {
        val state = loadState()
        val now = System.currentTimeMillis()
        val db = writableDatabase
        db.beginTransaction()
        try {
            val result = StepCounterLogic.onReading(
                state, raw, now, SystemClock.elapsedRealtime(), bootCount(context)
            ) { hour, steps ->
                // (UPSERT syntax needs SQLite 3.24 / API 30; minSdk is 26.)
                db.execSQL(
                    "INSERT OR IGNORE INTO hourly(hour_ms, steps, updated_ms) VALUES(?, 0, ?)",
                    arrayOf<Any>(hour, now)
                )
                db.execSQL(
                    "UPDATE hourly SET steps = steps + ?, updated_ms = ? WHERE hour_ms = ?",
                    arrayOf<Any>(steps, now, hour)
                )
            }
            saveState(state)
            prefs.edit().putLong("last_reading_ms", now).apply()
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }

    fun hourly(fromMs: Long, toMs: Long): List<Map<String, Long>> {
        val out = ArrayList<Map<String, Long>>()
        readableDatabase.rawQuery(
            "SELECT hour_ms, steps, updated_ms FROM hourly WHERE hour_ms >= ? AND hour_ms < ? ORDER BY hour_ms",
            arrayOf(fromMs.toString(), toMs.toString())
        ).use { c ->
            while (c.moveToNext()) {
                out.add(mapOf("hour_ms" to c.getLong(0), "steps" to c.getLong(1), "updated_ms" to c.getLong(2)))
            }
        }
        return out
    }

    /** Phone-sensor steps for the current local calendar day. */
    fun todayLocal(): Long {
        val cal = Calendar.getInstance(TimeZone.getDefault())
        cal.set(Calendar.HOUR_OF_DAY, 0); cal.set(Calendar.MINUTE, 0)
        cal.set(Calendar.SECOND, 0); cal.set(Calendar.MILLISECOND, 0)
        val start = cal.timeInMillis
        readableDatabase.rawQuery(
            "SELECT COALESCE(SUM(steps), 0) FROM hourly WHERE hour_ms >= ? AND hour_ms < ?",
            arrayOf(StepCounterLogic.hourStart(start).toString(), (start + 26 * 3_600_000L).toString())
        ).use { c -> return if (c.moveToFirst()) c.getLong(0) else 0L }
    }

    fun lastReadingMs(): Long = prefs.getLong("last_reading_ms", 0L)

    fun prune(olderThanMs: Long) {
        writableDatabase.delete("hourly", "hour_ms < ?", arrayOf(olderThanMs.toString()))
    }

    fun diagnostics(context: Context): Map<String, Any> {
        val s = loadState()
        return mapOf(
            "sensor_available" to isSensorAvailable(context),
            "last_raw" to s.lastRaw,
            "last_reading_ms" to lastReadingMs(),
            "boot_count" to bootCount(context),
            "total_counted" to s.totalCounted,
            "background_enabled" to backgroundEnabled(),
            "sdk" to Build.VERSION.SDK_INT
        )
    }

    fun backgroundEnabled(): Boolean = prefs.getBoolean("background_enabled", false)
    fun setBackgroundEnabled(on: Boolean) = prefs.edit().putBoolean("background_enabled", on).apply()
    fun dailyGoal(): Long = prefs.getLong("daily_goal", 8000L)
    fun setDailyGoal(goal: Long) = prefs.edit().putLong("daily_goal", goal).apply()

    private fun loadState() = StepCounterLogic.State().apply {
        lastRaw = prefs.getLong("last_raw", -1L)
        lastWallMs = prefs.getLong("last_wall_ms", 0L)
        lastElapsedMs = prefs.getLong("last_elapsed_ms", 0L)
        bootCount = prefs.getLong("boot_count", -1L)
        totalCounted = prefs.getLong("total_counted", 0L)
    }

    private fun saveState(s: StepCounterLogic.State) {
        prefs.edit()
            .putLong("last_raw", s.lastRaw)
            .putLong("last_wall_ms", s.lastWallMs)
            .putLong("last_elapsed_ms", s.lastElapsedMs)
            .putLong("boot_count", s.bootCount)
            .putLong("total_counted", s.totalCounted)
            .apply()
    }

    companion object {
        @Volatile private var instance: StepStore? = null

        fun get(context: Context): StepStore =
            instance ?: synchronized(this) { instance ?: StepStore(context).also { instance = it } }

        fun isSensorAvailable(context: Context): Boolean {
            val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
            return sm.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) != null
        }

        fun bootCount(context: Context): Long = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT).toLong()
        } catch (e: Exception) {
            -1L
        }
    }
}
