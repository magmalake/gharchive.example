"""One hour of `gharchive.events` as index files: the rebuild that
gharchive_index runs for days loaded before the index tables existed, and
that gharchive runs for the hours a retried step skips as already committed
(their index files, never committed, were lost with the failed attempt).
"""

from parquet import RecordBatch

from cols import col, i64_at, str_at, str_range
from days import days_of
from hourindex import HourIndex, IndexFiles, write_index
from orca.tables import load_dataset

from lake import CANDIDATES, GH_RELEASES, REPO_HOUR, EVENTS


def _fold(mut index: HourIndex, b: RecordBatch, lo: Int64) raises:
    ref ty = b.column(col(b, "type"))
    ref rp = b.column(col(b, "repo"))
    ref ac = b.column(col(b, "actor"))
    ref at = b.column(col(b, "created_at"))
    ref pl = b.column(col(b, "payload"))
    var pv = Span(pl.values)
    for r in range(b.num_rows):
        var at_r = i64_at(at, r)
        if at_r < lo or at_r >= lo + 3_600_000_000:
            continue  # the filter keeps whole row groups
        var pr = str_range(pl, r)
        index.add(
            str_at(ty, r), str_at(rp, r), str_at(ac, r), at_r,
            pv[pr[0] : pr[1]],
        )


def index_job(day: String, hour: Int, snapshot: Int64, marker: Bool) -> String:
    """The `index_hour` job for an hour: `marker` is whether an hour with
    nothing for a table writes the marker row (gharchive_index commits an
    hour at a time and needs it; gharchive commits a day and doesn't)."""
    return String(day, "\n", hour, "\n", snapshot, "\n", 1 if marker else 0)


def index_hour(job: String) raises -> IndexFiles:
    """On a worker: one hour of `gharchive.events` (at the snapshot in `job`,
    `day\\nhour\\nsnapshot[\\nmarker]`) as index files, uncommitted."""
    var parts = job.split("\n")
    var day = String(parts[0])
    var hour = Int(parts[1])
    var snapshot = Int64(Int(parts[2]))
    var lo = days_of(day) * 86_400_000_000 + Int64(hour) * 3_600_000_000
    var marker = len(parts) < 4 or String(parts[3]) != "0"
    var index = HourIndex(lo if marker else 0)
    try:
        var events = load_dataset(EVENTS)
        var filter = String(
            '["and",[">=","created_at",', lo, '],["<","created_at",',
            lo + 3_600_000_000, "]]",
        )
        var reader = (
            events.scan()
            .use_snapshot(snapshot)
            .filter(filter)
            .select(["type", "repo", "actor", "created_at", "payload"])
            .to_batch_reader()
        )
        while True:
            var next = reader.next_batch()
            if not next:
                break
            _fold(index, next.take(), lo)
        return write_index(
            index,
            load_dataset(CANDIDATES),
            load_dataset(REPO_HOUR),
            load_dataset(GH_RELEASES),
        )
    except e:
        raise Error(day, " hour ", hour, ": ", e)
