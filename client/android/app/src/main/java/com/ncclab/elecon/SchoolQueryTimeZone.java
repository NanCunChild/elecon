package com.ncclab.elecon;

import java.time.DateTimeException;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.time.ZoneId;

/** ADR-096: platform IANA rules, without device-zone or interval inference. */
public final class SchoolQueryTimeZone {
    private SchoolQueryTimeZone() {}

    public static String validate(String name, String startAt, String endAt) {
        if (name == null || name.length() > 128 || !ZoneId.getAvailableZoneIds().contains(name)) {
            return "unknown";
        }
        final ZoneId zone;
        try {
            zone = ZoneId.of(name);
        } catch (DateTimeException error) {
            return "unknown";
        }
        try {
            String minute = "^\\d{4}-\\d{2}-\\d{2}T(?:[01]\\d|2[0-3]):[0-5]\\d:00(?:Z|[+-](?:0\\d|1[0-4]):[0-5]\\d)$";
            if (startAt == null || endAt == null || !startAt.matches(minute) || !endAt.matches(minute)) {
                return "mismatch";
            }
            OffsetDateTime start = OffsetDateTime.parse(startAt);
            OffsetDateTime end = OffsetDateTime.parse(endAt);
            if (start.getYear() < 1 || end.getYear() < 1
                    || !start.toLocalDate().equals(end.toLocalDate())
                    || !start.getOffset().equals(end.getOffset())
                    || Math.abs(start.getOffset().getTotalSeconds()) > 14 * 3600
                    || !end.toInstant().isAfter(start.toInstant())
                    || Duration.between(start.toInstant(), end.toInstant()).toMinutes() > 720) {
                return "mismatch";
            }
            // A gap has no valid offset; a repeated time has two. The caller's
            // explicit offset must select an actual occurrence at BOTH ends.
            return zone.getRules().getValidOffsets(start.toLocalDateTime()).contains(start.getOffset())
                    && zone.getRules().getValidOffsets(end.toLocalDateTime()).contains(end.getOffset())
                    ? "valid" : "mismatch";
        } catch (DateTimeException error) {
            return "mismatch";
        }
    }
}
