#!/usr/bin/env bash
# Compiles and runs the Android step-counter logic tests with only a JDK (no Android
# SDK, Gradle or network). Uses a tiny stand-in for the JUnit 4 API. In a full
# Android build the same test runs via: cd android && ./gradlew testDebugUnitTest
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src/org/junit"
cat > "$WORK/src/org/junit/Test.java" <<'J'
package org.junit;
import java.lang.annotation.*;
@Retention(RetentionPolicy.RUNTIME) @Target(ElementType.METHOD) public @interface Test {}
J
cat > "$WORK/src/org/junit/Assert.java" <<'J'
package org.junit;
public final class Assert {
  public static void assertTrue(boolean c) { if (!c) throw new AssertionError("expected true"); }
  public static void assertFalse(boolean c) { if (c) throw new AssertionError("expected false"); }
  public static void assertEquals(long e, long a) { if (e != a) throw new AssertionError("expected " + e + " but was " + a); }
  public static void assertEquals(Object e, Object a) { if (e == null ? a != null : !e.equals(a)) throw new AssertionError("expected " + e + " but was " + a); }
}
J
cat > "$WORK/src/Runner.java" <<'J'
import java.lang.reflect.*;
public class Runner {
  public static void main(String[] a) throws Exception {
    Class<?> c = Class.forName(a[0]); int pass = 0, fail = 0;
    for (Method m : c.getDeclaredMethods()) {
      if (!m.isAnnotationPresent(org.junit.Test.class)) continue;
      try { m.invoke(c.getDeclaredConstructor().newInstance()); System.out.println("  PASS " + m.getName()); pass++; }
      catch (InvocationTargetException e) { System.out.println("  FAIL " + m.getName() + ": " + e.getCause()); fail++; }
    }
    System.out.println(pass + " passed, " + fail + " failed");
    if (fail > 0) System.exit(1);
  }
}
J
javac -d "$WORK/out" "$WORK"/src/org/junit/*.java "$WORK/src/Runner.java" \
  "$ROOT/android/app/src/main/java/com/stridemate/app/steps/StepCounterLogic.java" \
  "$ROOT/android/app/src/test/java/com/stridemate/app/steps/StepCounterLogicTest.java" 2>&1 | grep -v JAVA_TOOL_OPTIONS || true
java -cp "$WORK/out" Runner com.stridemate.app.steps.StepCounterLogicTest 2>&1 | grep -v JAVA_TOOL_OPTIONS
