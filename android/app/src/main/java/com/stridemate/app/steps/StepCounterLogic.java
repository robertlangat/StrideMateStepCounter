package com.stridemate.app.steps;

/**
 * Pure (Android-free) logic that turns readings of Android's cumulative
 * TYPE_STEP_COUNTER sensor into per-hour step buckets.
 *
 * The hardware counter reports steps since boot. This class handles:
 *  - first reading after install (baseline only - we cannot know when earlier steps happened);
 *  - reboots (counter resets; detected by boot count, counter going backwards, or
 *    monotonic clock going backwards) - steps since boot are attributed to [boot, now];
 *  - wall-clock / time-zone changes - durations come from the monotonic clock, so
 *    changing the phone's time cannot create or destroy steps;
 *  - long gaps (app not running) - steps are spread across the hours of the gap
 *    proportionally to time, never dumped into the current hour;
 *  - implausible jumps (sensor glitches) - capped at 250 steps/minute of elapsed time.
 *
 * Buckets are keyed by the UTC epoch millis of the hour start. Hour boundaries in UTC
 * are hour boundaries in every whole-hour time zone; the app converts to local days.
 */
public final class StepCounterLogic {
    public static final long HOUR_MS = 3_600_000L;
    public static final long MAX_SPREAD_MS = 7L * 24 * HOUR_MS;
    public static final double MAX_STEPS_PER_MINUTE = 250.0;
    public static final long GLITCH_ALLOWANCE = 50;

    private StepCounterLogic() {}

    /** Persisted between readings. */
    public static final class State {
        public long lastRaw = -1;
        public long lastWallMs = 0;
        public long lastElapsedMs = 0;
        public long bootCount = -1;
        public long totalCounted = 0;
    }

    /** Receives step increments for an hour bucket. */
    public interface Sink {
        void add(long hourStartUtcMs, long steps);
    }

    /** Outcome of one reading, for diagnostics and tests. */
    public static final class Result {
        public final long counted;
        public final boolean reboot;
        public final boolean clamped;
        public final boolean baseline;

        Result(long counted, boolean reboot, boolean clamped, boolean baseline) {
            this.counted = counted;
            this.reboot = reboot;
            this.clamped = clamped;
            this.baseline = baseline;
        }
    }

    public static long hourStart(long wallMs) {
        return Math.floorDiv(wallMs, HOUR_MS) * HOUR_MS;
    }

    /**
     * @param raw        sensor value (steps since boot)
     * @param wallMs     System.currentTimeMillis()
     * @param elapsedMs  SystemClock.elapsedRealtime() (monotonic, since boot)
     * @param bootCount  Settings.Global.BOOT_COUNT, or -1 if unavailable
     */
    public static Result onReading(State s, long raw, long wallMs, long elapsedMs, long bootCount, Sink sink) {
        if (raw < 0) {
            return new Result(0, false, false, false);
        }
        if (s.lastRaw < 0) {
            remember(s, raw, wallMs, elapsedMs, bootCount);
            return new Result(0, false, false, true);
        }

        boolean bootChanged = bootCount >= 0 && s.bootCount >= 0 && bootCount != s.bootCount;
        boolean reboot = bootChanged || raw < s.lastRaw || elapsedMs < s.lastElapsedMs;

        long delta;
        long durationMs;
        if (reboot) {
            delta = raw;                        // steps since this boot
            durationMs = Math.max(0, elapsedMs); // they happened between boot and now
            long sinceLast = wallMs - s.lastWallMs;
            if (sinceLast > 0 && sinceLast < durationMs) {
                durationMs = sinceLast;          // never attribute before the last reading
            }
        } else {
            delta = raw - s.lastRaw;
            durationMs = elapsedMs - s.lastElapsedMs;
        }

        boolean clamped = false;
        long max = (long) Math.ceil(durationMs / 60_000.0 * MAX_STEPS_PER_MINUTE) + GLITCH_ALLOWANCE;
        if (delta > max) {
            delta = max;
            clamped = true;
        }

        if (delta > 0) {
            long spread = Math.min(durationMs, MAX_SPREAD_MS);
            distribute(wallMs - spread, wallMs, delta, sink);
            s.totalCounted += delta;
        }
        remember(s, raw, wallMs, elapsedMs, bootCount);
        return new Result(Math.max(delta, 0), reboot, clamped, false);
    }

    /** Spread {@code steps} over [startMs, endMs] proportionally to each hour's overlap. */
    static void distribute(long startMs, long endMs, long steps, Sink sink) {
        if (steps <= 0) return;
        if (endMs <= startMs) {
            sink.add(hourStart(endMs), steps);
            return;
        }
        long total = endMs - startMs;
        long assigned = 0;
        long cursor = startMs;
        long lastHour = hourStart(endMs == hourStart(endMs) ? endMs - 1 : endMs);
        while (cursor < endMs) {
            long h = hourStart(cursor);
            long segEnd = Math.min(h + HOUR_MS, endMs);
            long share;
            if (h == lastHour) {
                share = steps - assigned;       // remainder goes to the final hour: totals are exact
            } else {
                share = Math.round((double) steps * (segEnd - cursor) / total);
                share = Math.min(share, steps - assigned);
            }
            if (share > 0) {
                sink.add(h, share);
                assigned += share;
            }
            cursor = segEnd;
        }
    }

    private static void remember(State s, long raw, long wallMs, long elapsedMs, long bootCount) {
        s.lastRaw = raw;
        s.lastWallMs = wallMs;
        s.lastElapsedMs = elapsedMs;
        if (bootCount >= 0) s.bootCount = bootCount;
    }
}
