"""Days as `date` values (days since 1970-01-01), their text and months."""

from jscan import days_from_civil, micros_to_iso


def day_text(days: Int64) -> String:
    """`YYYY-MM-DD`."""
    var iso = micros_to_iso(days * 86_400_000_000)
    return String(iso[byte=:10])


def days_of(text: String) raises -> Int64:
    """The days of a `YYYY-MM-DD`."""
    if text.byte_length() < 10:
        raise Error("not a day: ", text)
    return Int64(
        days_from_civil(
            Int(text[byte=0:4]), Int(text[byte=5:7]), Int(text[byte=8:10])
        )
    )


def month_of(days: Int64) raises -> Int:
    """Months since 1970-01, as Iceberg's `month` transform numbers them."""
    var t = day_text(days)
    return (Int(t[byte=0:4]) - 1970) * 12 + Int(t[byte=5:7]) - 1
