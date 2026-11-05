package dev.nancunchild.elecon;

/** Dependency-free JVM checks for the exact java.time validator used on Android. */
public final class SchoolQueryTimeZoneTest {
    private static int checks;

    private static void expect(String result, String zone, String start, String end) {
        String actual = SchoolQueryTimeZone.validate(zone, start, end);
        if (!result.equals(actual)) throw new AssertionError(zone + ": expected " + result + ", got " + actual);
        checks++;
    }

    public static void main(String[] ignored) {
        expect("valid", "Asia/Shanghai", "2026-11-05T08:00:00+08:00", "2026-11-05T09:00:00+08:00");
        expect("mismatch", "Asia/Shanghai", "2026-11-05T08:00:00Z", "2026-11-05T09:00:00Z");
        expect("valid", "Asia/Kathmandu", "2026-11-05T08:00:00+05:45", "2026-11-05T09:00:00+05:45");
        expect("unknown", null, "2026-11-05T08:00:00Z", "2026-11-05T09:00:00Z");
        expect("unknown", "Invalid/Synthetic", "2026-11-05T08:00:00Z", "2026-11-05T09:00:00Z");
        expect("unknown", "+08:00", "2026-11-05T08:00:00+08:00", "2026-11-05T09:00:00+08:00");
        expect("unknown", "GMT+08:00", "2026-11-05T08:00:00+08:00", "2026-11-05T09:00:00+08:00");
        expect("mismatch", "UTC", "2026-02-30T08:00:00Z", "2026-02-30T09:00:00Z");
        expect("mismatch", "UTC", "2026-11-05T08:00:01Z", "2026-11-05T09:00:00Z");
        expect("mismatch", "UTC", "2026-11-05T23:00:00Z", "2026-11-06T00:00:00Z");
        expect("mismatch", "UTC", "2026-11-05T08:00:00Z", "2026-11-05T21:00:00Z");
        // The spring gap cannot be interpreted using either old or new offset.
        expect("mismatch", "America/New_York", "2026-03-08T02:10:00-05:00", "2026-03-08T02:40:00-05:00");
        expect("mismatch", "America/New_York", "2026-03-08T02:10:00-04:00", "2026-03-08T02:40:00-04:00");
        expect("valid", "America/New_York", "2026-03-08T03:10:00-04:00", "2026-03-08T03:40:00-04:00");
        // Both explicit occurrences of the fall overlap are valid.
        expect("valid", "America/New_York", "2026-11-01T01:10:00-04:00", "2026-11-01T01:40:00-04:00");
        expect("valid", "America/New_York", "2026-11-01T01:10:00-05:00", "2026-11-01T01:40:00-05:00");
        expect("mismatch", "America/New_York", "2026-11-01T01:10:00-06:00", "2026-11-01T01:40:00-06:00");
        // Checking only the first endpoint would incorrectly accept this.
        expect("mismatch", "America/New_York", "2026-11-01T01:10:00-04:00", "2026-11-01T02:10:00-04:00");
        expect("mismatch", "America/New_York", "2026-11-01T01:10:00-04:00", "2026-11-01T01:40:00-05:00");
        System.out.println("SchoolQueryTimeZone: " + checks + " checks passed");
    }
}
