"""A digest of a gharchive table, for comparing two warehouses: the number of
rows that are not marker rows (no repository), an order-independent hash of
those, how many marker rows there are, and the number of snapshots.

    ORCA_WAREHOUSE=build/warehouse pixi run mojo run -I src tools/dump_index.mojo gharchive.candidates

`scripts/test-daily.sh` compares these across runs. Tables: gharchive.candidates,
gharchive.repo_hour, gharchive.releases.
"""

from std.sys import argv

from cols import bool_at, col, i64_at, str_at
from lake import load


def _names(dataset: String) raises -> List[String]:
    if dataset == "gharchive.candidates":
        return ["repo", "hour", "reason", "first_seen", "sha"]
    if dataset == "gharchive.repo_hour":
        return [
            "repo", "hour", "actor", "events", "stars", "forks", "releases",
            "issues_opened", "prs_opened", "pushes",
        ]
    if dataset == "gharchive.releases":
        return [
            "repo", "created_at", "actor", "tag", "name", "published_at",
            "prerelease",
        ]
    raise Error("unknown table ", dataset)


def _kinds(dataset: String) raises -> String:
    """One letter a column, in the same order: S string, I long or
    timestamp, B boolean."""
    if dataset == "gharchive.candidates":
        return "SISIS"
    if dataset == "gharchive.repo_hour":
        return "SISIIIIIII"
    return "SISSSIB"


def main() raises:
    var dataset = String(argv()[1])
    var dot = dataset.find(".")
    var t = load(String(dataset[byte=:dot]), String(dataset[byte = dot + 1 :]))
    var kinds = _kinds(dataset)
    var names = _names(dataset)
    var reader = t.scan().select(names.copy()).to_batch_reader()
    var rows = 0
    var markers = 0
    var digest = UInt64(0)
    while True:
        var next = reader.next_batch()
        if not next:
            break
        var b = next.take()
        for r in range(b.num_rows):
            var line = String()
            for c in range(len(names)):
                ref a = b.column(col(b, names[c]))
                var k = kinds[byte=c]
                if k == "S":
                    line.write(str_at(a, r), "\x1f")
                elif k == "I":
                    line.write(i64_at(a, r), "\x1f")
                else:
                    line.write(bool_at(a, r), "\x1f")
            rows += 1
            if str_at(b.column(col(b, "repo")), r).byte_length() == 0:
                markers += 1
                continue
            digest += UInt64(hash(line))
    print(
        dataset, ": rows ", rows - markers, " digest ", digest, " markers ",
        markers, " snapshots ", len(t.metadata.snapshots), sep="",
    )
