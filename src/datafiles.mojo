"""Data files written on a dista worker, sent back to the step to commit.

An hour's task writes its Parquet files into the table's `data/` itself and
returns only their `DataFile` entries (`orca.tables.DataFiles`, which dista
carries as a `Codec`), which the step commits as one append
(`orca.tables.append_files`).
"""

from std.time import perf_counter_ns

from iceberg.catalog.filesystem import Table
from orca.tables import DataFiles as FileEntries
from orca.tables import FileWriter
from parquet import RecordBatch

from hourindex import IndexFiles
from sortrows import sorted_by_text


struct DataFiles(Copyable, Movable):
    """An hour's data files, its row count, and where its time went (ms).

    A plain struct: dista's reflection encodes its fields, `files` through
    its own `Codec`."""

    var files: FileEntries
    var rows: Int
    var download_ms: Int
    var gunzip_ms: Int
    var parse_ms: Int
    var sort_ms: Int
    """Putting each batch's rows in order, before they are written."""
    var write_ms: Int
    var wait_ms: Int
    """Decoding waiting for the download."""
    var total_ms: Int
    var index: IndexFiles
    """The hour's candidates, repository counts and releases."""
    var index_ms: Int
    """Building them and writing their files."""

    def __init__(out self):
        self.files = FileEntries()
        self.rows = 0
        self.download_ms = 0
        self.gunzip_ms = 0
        self.parse_ms = 0
        self.sort_ms = 0
        self.write_ms = 0
        self.wait_ms = 0
        self.total_ms = 0
        self.index = IndexFiles()
        self.index_ms = 0


trait BatchSink:
    """Where `parse_gz` puts each batch as it fills: a table writer in the
    hour task, a plain list in tests."""

    def put(mut self, var batch: RecordBatch) raises:
        ...


struct TableWriter(BatchSink, Movable):
    """Writes batches into a table's data files as they come, uncommitted
    (an `orca.tables.FileWriter`), and keeps their entries and the time."""

    var writer: FileWriter
    var write_ns: Int
    var sort_ns: Int
    var sort_first: String
    var sort_second: String
    """The string columns each batch's rows are put in the order of before it
    is written (see `sortrows`); empty for the order they arrived in."""

    def __init__(
        out self,
        table: Table,
        sort_first: String = "",
        sort_second: String = "",
    ) raises:
        self.writer = FileWriter(table)
        # One thread per core encodes each file's pages. 4 MB pages: the
        # JSON column's 20% growth at the 1 MB default is 4% at 4 MB.
        self.writer.options.num_workers = 0
        if "write.parquet.page-size-bytes" not in table.metadata.properties:
            self.writer.options.page_size = 4 * 1024 * 1024
        self.write_ns = 0
        self.sort_ns = 0
        self.sort_first = sort_first
        self.sort_second = sort_second

    def put(mut self, var batch: RecordBatch) raises:
        """Sorts the batch if asked to (each batch on its own: rows are in
        order within a batch, not across the hour), then writes it."""
        if self.sort_first:
            var t_sort = perf_counter_ns()
            batch = sorted_by_text(batch, self.sort_first, self.sort_second)
            self.sort_ns += Int(perf_counter_ns() - t_sort)
        var t0 = perf_counter_ns()
        self.writer.put(batch^)
        self.write_ns += Int(perf_counter_ns() - t0)

    def finish(deinit self) -> DataFiles:
        """Closes the last file and returns the entries of all of them, with
        the row count and the time spent sorting and writing."""
        var out = DataFiles()
        out.rows = self.writer.rows
        out.sort_ms = self.sort_ns // 1_000_000
        out.write_ms = self.write_ns // 1_000_000
        out.files = self.writer^.finish()
        return out^
