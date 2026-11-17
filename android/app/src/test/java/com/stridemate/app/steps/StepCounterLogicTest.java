package com.stridemate.app.steps;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.Map;
import java.util.TreeMap;
import org.junit.Test;

public class StepCounterLogicTest {
    private static final long H = StepCounterLogic.HOUR_MS;
    private static final long M = 60_000L;
    // 2026-11-16T21:30:00Z  (00:30 next day in Africa/Nairobi)
    private static final long T0 = 1_794_000_000_000L - (1_794_000_000_000L % H) + 30 * M;

    private final Map<Long, Long> buckets = new TreeMap<>();
    private final StepCounterLogic.Sink sink = (hour, steps) -> buckets.merge(hour, steps, Long::sum);

    private long total() {
        return buckets.values().stream().mapToLong(Long::longValue).sum();
    }

    @Test
    public void firstReadingIsBaselineOnly() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.Result r = StepCounterLogic.onReading(s, 52_000, T0, 10 * H, 3, sink);
        assertTrue(r.baseline);
        assertEquals(0, total());
    }

    @Test
    public void countsDeltasIntoCurrentHour() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 1000, T0, 10 * H, 3, sink);
        StepCounterLogic.onReading(s, 1600, T0 + 10 * M, 10 * H + 10 * M, 3, sink);
        assertEquals(600, total());
        assertEquals(Long.valueOf(600), buckets.get(StepCounterLogic.hourStart(T0)));
    }

    @Test
    public void spreadsLongGapAcrossHoursAndKeepsExactTotal() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 0, T0, 10 * H, 3, sink);
        // app was not running for 3 hours; 4,001 steps happened meanwhile
        StepCounterLogic.onReading(s, 4001, T0 + 3 * H, 13 * H, 3, sink);
        assertEquals(4001, total());
        assertEquals(4, buckets.size()); // 21:30-22, 22-23, 23-00, 00-00:30
        assertTrue(buckets.get(StepCounterLogic.hourStart(T0)) < buckets.get(StepCounterLogic.hourStart(T0) + H));
    }

    @Test
    public void midnightRolloverSplitsAtHourBoundary() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        long beforeMidnightUtc = (T0 / (24 * H)) * 24 * H + 24 * H - 30 * M; // 23:30Z
        StepCounterLogic.onReading(s, 0, beforeMidnightUtc, 5 * H, 7, sink);
        StepCounterLogic.onReading(s, 600, beforeMidnightUtc + 60 * M, 6 * H, 7, sink);
        assertEquals(600, total());
        assertEquals(Long.valueOf(300), buckets.get(StepCounterLogic.hourStart(beforeMidnightUtc)));
        assertEquals(Long.valueOf(300), buckets.get(StepCounterLogic.hourStart(beforeMidnightUtc) + H));
    }

    @Test
    public void rebootDetectedByCounterReset() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 9000, T0, 20 * H, -1, sink);
        // phone rebooted 30 min ago; counter restarted from 0 and now reads 700
        StepCounterLogic.Result r = StepCounterLogic.onReading(s, 700, T0 + 2 * H, 30 * M, -1, sink);
        assertTrue(r.reboot);
        assertEquals(700, total());
        assertEquals(Long.valueOf(700), buckets.get(StepCounterLogic.hourStart(T0 + 2 * H)));
    }

    @Test
    public void rebootDetectedByBootCountEvenIfCounterHigher() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 100, T0, 1 * H, 4, sink);
        StepCounterLogic.Result r = StepCounterLogic.onReading(s, 5000, T0 + 5 * H, 2 * H, 5, sink);
        assertTrue(r.reboot);
        assertEquals(5000, total()); // not 4,900: the old baseline belongs to the previous boot
    }

    @Test
    public void wallClockJumpBackDoesNotLoseOrInventSteps() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 0, T0, 10 * H, 3, sink);
        // user moved the clock back 5 hours (or changed time zone + auto time glitch)
        StepCounterLogic.Result r = StepCounterLogic.onReading(s, 300, T0 - 5 * H + 5 * M, 10 * H + 5 * M, 3, sink);
        assertFalse(r.reboot);
        assertEquals(300, total());
    }

    @Test
    public void implausibleJumpIsClamped() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 0, T0, 10 * H, 3, sink);
        StepCounterLogic.Result r = StepCounterLogic.onReading(s, 90_000, T0 + 2 * M, 10 * H + 2 * M, 3, sink);
        assertTrue(r.clamped);
        assertEquals(550, total()); // 2 min * 250 + 50 allowance
    }

    @Test
    public void duplicateReadingCountsNothing() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 10, T0, 10 * H, 3, sink);
        StepCounterLogic.onReading(s, 50, T0 + M, 10 * H + M, 3, sink);
        StepCounterLogic.onReading(s, 50, T0 + M, 10 * H + M, 3, sink);
        StepCounterLogic.onReading(s, 50, T0 + 2 * M, 10 * H + 2 * M, 3, sink);
        assertEquals(40, total());
    }

    @Test
    public void veryLongGapSpreadIsBoundedToSevenDays() {
        StepCounterLogic.State s = new StepCounterLogic.State();
        StepCounterLogic.onReading(s, 0, T0, 10 * H, 3, sink);
        StepCounterLogic.onReading(s, 70_000, T0 + 30 * 24 * H, 10 * H + 30 * 24 * H, 3, sink);
        assertEquals(70_000, total());
        long earliest = buckets.keySet().iterator().next();
        assertTrue(earliest >= StepCounterLogic.hourStart(T0 + 23 * 24 * H));
    }
}
