# Gaps found while building mojo-census

A running list of where the magmalake skills (orca, dista, magmalake-apps,
mojo-data-performance), mojoshelf's skills and the libraries were wrong,
silent or misleading, written while building this project from PROMPT.md
with only those as documentation. Each entry: what I tried, what happened,
what I did instead, and what would fix it.

Severity: **high** (a user is stuck or gets wrong results), **medium** (costs
an hour or needs reading library source), **low** (friction).

---

## 1. The installed environment has no sources or docs for most tins (medium)

- **Tried:** to read the API of iceberg, dista, orca, deflate and parquet
  "in `.pixi/envs/default/`", as a user's agent would after `pixi shelf add`.
- **Happened:** `lib/mojo/` holds only compiled `*.mojoc` packages for 20 of
  the 22 tins (`orca.mojoc`, `iceberg.mojoc`, `dista.mojoc`, ...). Only
  `flare/` and `json/` are there as source. The skills point at files that
  aren't installed: orca's `examples/taxi/tlc.mojo` and
  `examples/taxi/taxi.mojo`, `src/orca/ui.mojo` (`struct Ui`),
  `scripts/with-postgres.sh` (the skill does say "the tin doesn't ship it"),
  iceberg.mojo's README ("the whole grammar").
- **Did instead:** found pixi's git checkouts of the pinned revisions in
  `~/Library/Caches/rattler/cache/git-v0/checkouts/<hash>/<rev7>/` (one
  directory per repository, named by an opaque hash) and read the published
  sources there. That is the same code as GitHub at the pinned commit, but a
  user would never find it.
- **Fix:** mojoshelf-consume: say where the source of a pixi-mode tin is
  (the GitHub URL at the `rev` in `pixi.toml`, or the rattler cache path),
  or have `pixi shelf add` print it; or have `shelf` offer `shelf source
  <tin>` that prints/clones the pinned checkout. magmalake-apps: link every
  file it cites with a pinned GitHub URL.

## 2. A pipeline binary run outside `pixi run` aborts in zstd with a misleading path (high; fixed in zstd-mojo 0.1.5)

- **Tried:** `./build/gharchive run --partitions 2025-09-15` from a plain
  shell (after building with `pixi run mojo build`).
- **Happened:** the run downloaded and parsed the hour, then aborted while
  writing Parquet:
  `ABORT: .../zstd/__init__.mojo:48:14: zstd.mojo: dlopen failed:
  dlopen(build/libzstdmojo.so, 0x000A): tried: 'build/libzstdmojo.so' (no
  such file), ...` plus a stack dump. zstd-mojo finds its C shim through
  `$CONDA_PREFIX/lib`, and falls back to `build/libzstdmojo.so` relative to
  the current directory (a path for zstd.mojo's own checkout), so the error
  names a file the user has never heard of.
- **Did instead:** ran every binary as `pixi run ./build/...`.
- **Fix:** zstd-mojo: when `CONDA_PREFIX` is unset, look next to the
  executable / in the rpath, and say "set CONDA_PREFIX or run inside `pixi
  run`" in the abort. magmalake-apps: make "run them in `pixi shell` or with
  `pixi run`" a Common mistake with this exact error text; today it's one
  sentence that reads as optional. (On AWS the image presumably sets it.)
- **Fixed:** zstd-mojo 0.1.5 finds its shim without `CONDA_PREFIX` and
  raises instead of aborting. `./build/gharchive run` (zstd Parquet) and
  `./build/console` both ran from a plain shell with `CONDA_PREFIX` unset.

## 3. GH Archive has no file lists in push events (data limitation; medium for the prompt)

- **Tried:** to find "pushes touching `.mojo` or `.🔥` files" from
  `gharchive.events`.
- **Happened:** `PushEvent` payloads hold commits' SHAs and messages, never
  their files. Recent hours are also much smaller: 2026-11-01 hour 0 is 6 MB
  against 94 MB for 2025-09-15 hour 0, as GitHub trimmed event payloads.
- **Did instead:** candidates come from cheap signals in the events (repo
  names, `"language":"Mojo"` in the repository objects pull-request and fork
  payloads embed, commit messages naming `.mojo` / `.🔥` files or
  `mojoproject.toml`), then each candidate is verified against GitHub: its
  `language`, its `pixi.toml` / `mojoproject.toml` on raw.githubusercontent
  (not rate-limited like the API), and for push candidates the head commit's
  files from the REST API. That last check needs API budget, which is 60
  requests an hour without a token.
- **Fix:** none in magmalake; the PROMPT could say "pushes whose commits
  touch ..., checked against GitHub's API".

## 4. `orca.tables`: several appends in one step work, but the skill doesn't say so (medium)

- **Tried:** to append one hour at a time from a day's step, so a day never
  sits in memory whole (a day of GH Archive is ~15 GB of JSON).
- **Happened:** the skills describe `append` as "commits ... as one snapshot"
  and the retry rule as "finds the snapshot its attempt already made",
  which reads as one commit per step. orca's `tables.mojo` source says each
  commit is numbered (`Ctx.made`, "as its next commit") and
  `find_commit(ctx, table)` answers for the *next* one.
- **Did instead:** read `src/orca/tables.mojo` in the rattler cache (gap 1).
  `load_day` calls `find_commit` before each hour and, if the earlier attempt
  committed it, calls `append(ctx, table, [])` to step past it without
  downloading the hour again.
- **Fix:** orca skill, "Datasets and Iceberg tables": "A step may commit
  several times; each commit is numbered, and a retry recognises the first
  N its last attempt made. Call `find_commit` first to skip work an attempt
  already committed."

## 5. deflate-mojo is raw DEFLATE only; there's no gzip (low; fixed in deflate-mojo 0.1.3)

- **Tried:** to decompress GH Archive's `.json.gz` with a tin.
- **Happened:** `deflate-mojo` is raw RFC 1951 by design ("Raw means raw");
  no tin reads gzip framing. zstd/brotli/lz4/snappy don't help.
- **Did instead:** `src/gz.mojo`, 40 lines: the RFC 1952 header, `inflate_at`,
  the 8-byte trailer, and concatenated members. It does 690 MB of JSON in
  0.8 s on an M-series Mac, so speed is fine.
- **Fix:** add `gunzip` / `gzip` to deflate-mojo (or a `gzip-mojo` tin) and
  list it in mojoshelf; mojo-data-performance's readers-and-codecs could
  mention it.
- **Fixed:** deflate-mojo 0.1.3 has `gunzip`, `gunzip_at` and `gzip`
  (`from deflate import gunzip`), with the CRC checked. `src/gz.mojo` is
  gone; a day's two hours load in the same ~10 s as before.

## 6. Small API surprises (low)

- `RecordBatch.num_rows` is a field, but the lake reference's `ScanResult`
  has `num_rows()`: `'Int' does not implement the '__call__' method`.
- flare's `Response` can't give up its body: `return resp.body^` fails with
  `field 'resp.body._storage._alloc' destroyed out of the middle of a value`.
  `swap(body, resp.body)` works (and `swap` is a builtin; `from std.memory
  import swap` fails). A `take_body()` would help; so would a line in the
  apps skill, since every downloader hits it.
- The lake reference lists `timestamp` among the types but not how to make
  one: it's `Datum.integral(P_TIMESTAMPTZ, micros)` (`from iceberg.types
  import P_TIMESTAMPTZ`), found in `iceberg/values.mojo`.

## 7. orca refuses a keyed sensor over a dataset a dated pipeline writes (high; fixed in orca 0.3.1)

- **Tried:** what PROMPT.md asks and the orca skill shows: `mojo_history`
  keyed on `mojo.repos` (`partitions=Keyed["mojo.repos", ...]`,
  `sensor=True`), with `mojo.repos` written by the daily sensor
  `mojo_repos`.
- **Happened:** `orca register ./build/mojo_history` fails:
  `orca: .../build/mojo_history can't be registered: the sensor
  mojo_history (keyed) reads mojo.repos, which mojo_repos (daily) writes,
  and no rule turns a name into a date or a date into a name`. It fails
  the same with `reads=[REPOS]` removed: the keys dataset counts as a read
  (`kind_mismatch` in `src/orca/scheduler.mojo`). The skill's own sample
  (`Keyed["lake.repos", "repo"]`, "new snapshots start runs, for the keys
  that are new") can only register if nothing dated writes `lake.repos`,
  which in practice means nothing in orca writes it.
- **Did instead:** `mojo_repos` also writes the new repositories' keys to
  a separate table, `mojo.repo_keys`, straight through iceberg
  (`lake.append_keys`), not declared in `writes=`. Registration passes, and
  the scheduler sees those snapshots by polling `mojo_history sense` and
  starts runs for the new keys (it worked: `sensed mojo.repo_keys@... for
  mojo_history 1 runs`). The cost: the lineage graph and the Datasets page
  don't show `mojo_repos → mojo.repo_keys → mojo_history`, and a retried
  `mojo_repos` can write a key twice (harmless for distinct keys).
  `mojo_history` reads `mojo.repos` sizes with `load_dataset`, undeclared,
  for the same reason.
- **Fix:** orca: a keyed sensor's *keys dataset* should be allowed to come
  from a dated pipeline; the new keys are the distinct values in the new
  snapshot, which needs no date↔name rule. (The refusal makes sense for the
  other direction, a dated sensor reading a keyed pipeline's output.) Until
  then, the orca skill should say plainly that a keyed sensor's keys must
  be written outside orca, and show the workaround.
- **Fixed:** orca 0.3.1 lets a dated pipeline write a keyed sensor's own
  keys dataset. mojo_history is now `Keyed["mojo.repos", "repo"]` with
  `sensor=True` and `reads=["mojo.repos"]`, scanned through `orca.tables`;
  `mojo.repo_keys` is gone. It registers, the scheduler logged `sensed
  mojo.repos@... for mojo_history 1 runs`, and `orca lineage mojo.commits`
  runs back to `gharchive.events`.

## 8. orca `Name` keys can't contain `/`, so repositories aren't keys (high; fixed in orca 0.3.1)

- **Tried:** keys `owner/name` (the natural key, and the skill's example
  is repositories: "for things that aren't dates and grow (repositories,
  devices, logs)").
- **Happened:** `./build/mojo_history run --partitions @all` prints
  `not a name (1 to 128 bytes of A-Z a-z 0-9 . _ : -, no '..'):
  'modular/modular'` and the usage text, and exits.
- **Did instead:** a `key` column, `owner:name` (GitHub owners can't
  contain `:`), and `lake.repo_key` / `key_repo` to convert.
- **Fix:** orca: allow `/` in names (it's the separator in run paths and log
  paths, so escape it there), or say the character set in the skill next to
  "The partition type is `Name`".
- **Fixed:** orca 0.3.1 allows `/` inside a name (log directories write it
  as `%2F`; a key's UI page is `/pipelines/<p>/keys/owner%2Fname`). Keys
  are `owner/name`; the `key` column and the conversions are gone.

## 9. Mojo 1.2.0's `String.splitlines()` splits on tabs (high: silently wrong numbers)

- **Tried:** to read `git log --numstat` (`added<TAB>deleted<TAB>path`)
  line by line with `splitlines()`.
- **Happened:** every numstat line came apart into three "lines", so no
  line matched and every repository had 0 lines of Mojo, with no error.
  `String("1\t2\tx.mojo\nnext").splitlines()` gives 4 items. (Python's
  `splitlines` doesn't split on `\t`; it looks like the range check covers
  0x09-0x0D instead of 0x0A-0x0D.)
- **Did instead:** `split("\n")`, and `tests/test_history.mojo` checks the
  numbers on a log with tabs. Note orca's own `scheduler.mojo` uses
  `splitlines()` on names files, so a tab there would split a name too.
- **Fix:** Modular's stdlib; until then mojo-syntax could warn
  "`splitlines()` also splits on `\t`".

## 10. A step's mapped partitions run one after another (medium)

- **Tried:** to read 50 repositories' histories in parallel, one dista
  task each, as the prompt says.
- **Happened:** nothing in the skills says whether mapped steps of a run
  run concurrently. orca's `pipeline.mojo` says steps run "in order", so a
  mapped step per key that calls one task and waits would read them one at
  a time. The orca skill does show a `Gather` step first in a pipeline
  only for `Seq[Month]` (in a test), not for keyed `Seq[Name]`.
- **Did instead:** `mojo_history` is one `Gather` step over `Seq[Name]`
  (it compiles and runs) that sends every repository to a task at once and
  collects them. The UI then shows one step for 50 repositories, and one
  repository's failure is reported in the log, not as a failed partition.
- **Fix:** orca skill: say that mapped steps run sequentially and that
  parallelism comes from dista tasks inside a step; show a keyed Gather.

## 11. A day's run that ran out of GitHub API budget can't be re-run by backfill (medium; fixed in orca 0.3.1)

- **Tried:** with the unauthenticated limit (60 requests an hour) used up,
  `mojo_repos` checks some candidates and leaves the rest. After the limit
  resets, `orca backfill mojo_repos 2024-06-12` to check the rest.
- **Happened:** backfills skip partitions that are done ("A key is done
  when every mapped step has succeeded for it in a run of the pipeline's
  current code"), so nothing was queued. Only the UI's Rerun, a manual
  `run`, or new code re-runs it.
- **Did instead:** unchecked candidates are recorded in `mojo.checked` as
  `unchecked`, and every later `mojo_repos` run checks them first, whatever
  day it is for. Locally, I re-ran the day with the UI's Rerun.
- **Fix:** orca: `orca backfill --force` (or `orca rerun <pipeline> KEY`)
  on the command line; the skill lists the UI's actions but not this
  limit of `backfill`.
- **Fixed:** orca 0.3.1 has `orca backfill --rerun <pipeline> KEY`, which
  queues keys that are done too. `orca backfill mojo_repos 2024-06-12`
  queued 0 runs; with `--rerun` it queued 1, which ran. The README says so.

## 12. Changing a table's schema means deleting it (medium; fixed in orca 0.3.1 with iceberg-mojo 0.8.6)

- **Tried:** to add two columns to `mojo.checked` after it had been
  created.
- **Happened:** `ensure_table` only creates; it never evolves an existing
  table, and iceberg-mojo reads evolved tables but has no API to add a
  column. Locally I deleted the table; on AWS, with the tables in the public
  bucket, that would mean losing data or writing metadata by hand.
- **Fix:** iceberg-mojo: `Table.add_column` / `update_schema`; orca:
  `ensure_table` adding missing optional columns; the lake reference should
  say what to do when a schema changes.
- **Fixed:** orca 0.3.1's `ensure_table` adds the optional columns a table
  lacks (through iceberg-mojo's `UpdateSchema.union_by_name`; new field ids
  follow the table's highest, in schema order). Not exercised here: this
  run started from an empty lake because `mojo.repos` lost its required
  `key` column, and dropping a column is still not something
  `ensure_table` does.

## 13. The default UI port can be taken, and the skills only name the variable once (low)

- **Tried:** `orca ui` while another orca UI (another project) ran.
- **Happened:** `AddressInUse: 127.0.0.1:8270`, and the process exited.
- **Did instead:** `ORCA_UI_ADDR=127.0.0.1:8271 ./build/orca ui`.
- **Fix:** none needed beyond the skill's existing mention in local.md;
  the error could say "set ORCA_UI_ADDR".

## 14. pixi tasks can't use shell loops (low)

- **Tried:** the local reference's build loop (`for p in pipelines/*.mojo;
  do ...; done`) as one pixi task, as it suggests ("A pixi task per
  program saves typing").
- **Happened:** `Error: × failed to parse shell script ... ╰─▶ Unsupported
  reserved word.` pixi's task shell has no `for`.
- **Did instead:** one task per program and a `build` task that depends on
  them.
- **Fix:** magmalake-apps local.md: show the `[tasks]` block.

## 15. A sensor only sees snapshots made after it was registered; the skills don't say so (medium)

- **Happened:** orca's `sensors.mojo` says "A sensor counts from when it's
  registered as one: the snapshots its datasets have then are recorded as
  seen without a run". The orca skill and the local reference say nothing
  about order, and their sample runs `register` right before `backfill`
  for one pipeline only. Loading the lake first and registering the
  sensors afterwards would start nothing.
- **Did instead:** registered all three pipelines, then backfilled.
- **Fix:** orca skill, "Keyed partitions and sensors": "Register sensors
  before the data they sense; use `backfill` or `rebuild` for what came
  before."

## 16. The UI's actions can't be scripted without knowing their form fields (low)

- **Tried:** `curl -X POST http://127.0.0.1:8271/runs/2/rerun` to re-run
  a day (gap 11).
- **Happened:** 403 `this form wasn't posted from orca ui's own pages (its
  Origin or Referer isn't this server)`; with an `Origin` header, 409 `Not
  done: pipeline mojo_repos has no step`; it needs `-d step=find_repos`.
- **Fix:** an `orca rerun <run> [--from STEP]` command, or a line in the
  skill on the UI's JSON actions.
- **Partly fixed:** for re-running a day, `orca backfill --rerun` (gap 11)
  needs no form. Rerunning one run from a step still does.

## 17. Smaller things

- mojoshelf-consume says pixi mode *requires* the
  `https://repo.prefix.dev/modular-community` channel; `pixi shelf add
  orca-mojo` worked without it (as the orca skill implies). One of them is
  out of date.
- `pixi shelf add orca-mojo` took 2.5 minutes and printed every tin's
  rattler-build log; a first-time user may think it hung.
- A repository `mojo_history` skipped (too big for `MOJO_HISTORY_MAX_KB`)
  still counts as done for orca, so reading it later needs a rerun or a
  rebuild. That's this project's choice, but orca has no "skipped"
  outcome for a key in a gather step.
- The `orca lineage mojo.commits` output showed no inputs (gap 7). Fixed
  in orca 0.3.1 with gap 7.

## 18. `pixi shelf update orca-mojo` fails half-way with "duplicate records" (high)

- **Tried:** `pixi shelf update` (refused in pixi mode: "pixi mode updates
  one tin at a time"), then `pixi shelf update orca-mojo`.
- **Happened:** it re-pins orca's dependencies one `pixi add --git` at a
  time, solving after each. After six of them it stopped at objectstore-mojo:
  `encountered duplicate records for objectstore-shim-0.2.0-hea27dcd_0_source.conda`
  (the new objectstore rev's shim and the old one, still pinned through
  packages not yet updated, have the same name, version and build). It
  exited 1 and left `pixi.toml` half-updated, those six lines moved to the
  end of `[dependencies]`, and orca itself not updated.
- **Did instead:** restored `pixi.toml` and `pixi.lock`, read each tin's
  latest `commit_sha` from `https://mojoshelf.org/api/tins/<name>`, wrote
  all 22 revs in one edit and ran `pixi install` once (2 minutes).
- **Fix:** mojoshelf: in pixi mode, `update` should compute the whole
  closure's revs, write them in one edit and solve once (and update every
  tin when no name is given); on failure, put `pixi.toml` back.

## 19. `pixi shelf list` prints every conda package (low)

- **Happened:** in pixi mode it prints the whole `pixi list` (python,
  tzdata, zlib, ...), not the tins and their pinned versions.
- **Fix:** mojoshelf: list only the tins, with version and rev.

## 20. deflate-mojo can't inflate a stream a window at a time (medium)

- **Tried:** to decode an hour of GH Archive (one gzip member, ~65 MB in,
  ~500 MB of JSON out) a window at a time, parsing lines as they come, so
  the hour's JSON is never in memory whole.
- **Happened:** deflate-mojo 0.1.3 has `gunzip`, `gunzip_at`, `inflate`
  and `inflate_at`, all of which return the whole output. GH Archive's
  files are single-member, so decoding member by member doesn't help. The
  decoder's state (`_BitReader`, `_Out`, the block loop in `_inflate_into`)
  isn't public or resumable.
- **Did instead:** `src/gzstream.mojo`, `GzipInflater`: deflate-mojo's
  Huffman decoding with its state kept between calls. `run(data,
  complete, want)` inflates blocks until the window holds `want` bytes;
  `compact` drops what the caller used, keeping the 32 KiB back-references
  reach. The input may still be arriving: a block that runs past it is
  rolled back and decoded again later. It also copies matches eight bytes
  at a time where the distance allows, rather than byte by byte. An hour
  now decodes and parses in 1.48 s instead of 0.58 + 1.09 s, and a
  worker's peak RSS fell (see the PR).
- **Fix:** deflate-mojo: a public streaming decoder (`Inflater` /
  `GzipReader` with `feed`/`read_into` or `run`/`compact` like this one),
  and the eight-byte match copy in `_Out.copy_match`.

## 21. Writing data files on a dista worker: no codec for `DataFile`, no "append these files" in orca (medium)

- **Tried:** to have each hour's dista task write its Parquet files into
  `gharchive.events` on the worker and send back only their entries, so
  the step commits metadata instead of receiving ~450 MB of Arrow per
  hour over IPC and writing it on one core.
- **Happened:** iceberg-mojo's `write_data_files` returns
  `List[DataFile]`, but `DataFile` (and `Datum`, `ColumnMetrics` in it)
  hold `List`s, which dista's reflection codec refuses, and iceberg has no
  serialised form short of a manifest. `orca.tables.append` only takes
  batches; neither the orca skill nor `tables.mojo` mentions committing
  files written elsewhere.
- **Did instead:** `src/datafiles.mojo`: `DataFiles`, a dista `Codec`
  that encodes every `DataFile` field by hand, and `TableWriter`, which
  writes each 50,000-row batch as soon as the parser fills it. The worker
  gets the table with `orca.tables.load_dataset` (workers have
  `ORCA_WAREHOUSE` on AWS too); the step commits with `orca.tables.commit(ctx,
  table, "append", FileChanges)`, which checks `find_commit` first, so the
  retry rule is unchanged. Six hours at PARALLEL=4: 7.8 -> 4.5 s, and a
  commit is ~1 ms. Files of an hour whose task finished but whose step
  died before committing are left as orphans (as an interrupted `append`
  already could).
- **Fix:** iceberg-mojo: `DataFile.encode`/`decode` (or a dista `Codec`
  in a small bridge), so file lists cross processes; orca:
  `append_files(ctx, table, files)` next to `append`, and a line in the
  skill that workers can write data files a step commits, with
  `load_dataset` on the worker.

## 22. json_mlake's simdjson path doesn't fit a scan for a few fields (low)

- **Tried:** json_mlake 0.4.3's simdjson FFI (`json.cpu.simdjson_ffi`,
  installed with flare) against the hand-written scanner in
  `src/jscan.mojo`, on an hour of GH Archive (491 MB, 142,347 lines).
- **Happened:** `SimdjsonFFI.parse` takes a `String`, so each line is
  copied first, and the DOM it builds has no way back to a value's bytes
  as written, which the `payload` column needs. Just parsing each line and
  walking its top-level keys ran at 457 MB/s; the old scanner, which found
  each of the six fields with its own `field` call (skipping the payload
  several times), ran at 494 MB/s.
- **Did instead:** `scan_event`: one walk of the line's top-level object
  that finds all six fields, stepping over string contents and nested
  values sixteen bytes at a time (`pack_bits` + `count_trailing_zeros`),
  and builds the Arrow columns directly instead of a `List[Datum]` per
  column. Parsing an hour fell from 1.10 s to 0.32 s (~1.5 GB/s), rows
  unchanged.
- **Fix:** json_mlake: a span-returning scan (`Span` input, value ranges
  out, like simdjson's on-demand `raw_json()`), or its stage-1
  structural index exposed, so callers can skip what they don't need.
  iceberg-mojo: a `ColumnBuilder` that appends bytes and integers without
  a `Datum` per cell.

## 23. Writing a batch through iceberg-mojo peaks at ~10x the batch (medium)

- **Happened:** one hour written as 50,000-row batches (~150 MB of
  payload each) peaks at 1.86 GB RSS in the worker; as 20,000-row
  batches, 1.0 GB, with gunzip and parsing needing ~150 MB. In
  `write_data_files` each batch is copied by `align_batch`
  (`subtree_copy`, then `cast_column`), again by `aligned[k].copy()` for
  an unpartitioned group, again by `write_parquet`'s `subtree_copy`, then
  encoded, compressed, returned as one `List[UInt8]`, and copied once
  more by `data_file_from_parquet` (`ParquetReader(data.copy())`) to read
  the footer back.
- **Did instead:** kept 50,000-row batches, so the files are as before;
  peak RSS is that of the writer.
- **Fix:** iceberg-mojo: move columns through `align_batch` when they
  already match the schema, skip the copy for a single group, build the
  `DataFile` from the writer's own metadata rather than re-reading the
  bytes; parquet.mojo: stream row groups to the output instead of
  holding the whole file.

---

## What the local run did, the orca way (orca 0.3.1)

A fresh lake and `orca` database (the `mojo.repos` schema changed), the
Postgres from conda-forge under `build/pg`, `scripts/env.sh`
(`GHARCHIVE_HOURS=15,17`, `MOJO_HISTORY_MAX_KB=100000`,
`ORCA_SENSE_SECONDS=10`), unauthenticated GitHub (59 requests left), then:

```
$ ./build/orca register ./build/gharchive ./build/mojo_repos ./build/mojo_history
registered gharchive
registered mojo_repos
registered mojo_history
$ ./build/orca scheduler & ORCA_UI_ADDR=127.0.0.1:8275 ./build/orca ui &
$ ./build/orca backfill gharchive 2024-06-12
queued 1 runs
```

The scheduler's log:

```
started gharchive run 1 pid 73578
reaped pid 73578 exit 0                       # 476,227 events, 2 hours, ~10 s
sensed gharchive.events@3037946910953850598 for mojo_repos run 2 for 2024-06-12
sensed gharchive.events@5050756693608396143 for mojo_repos run 2 for 2024-06-12
started mojo_repos run 2 pid 73599
reaped pid 73599 exit 0                       # 23 candidates checked, 4 Mojo repositories
sensed mojo.repos@1204299635680259392 for mojo_history 1 runs from run 3
started mojo_history run 3 pid 73618
reaped pid 73618 exit 0                       # 3 read, modular/modular skipped for size
```

`mojo_history` run 3, keyed `Mojo-Numerics-and-Algorithms-group/NuMojo`,
`modular/modular`, `mzaks/mojo-flx` and `sdgunaa/Mojonet`: NuMojo 210
commits and 21 migrations (69,563 lines of Mojo now), Mojonet 139 commits
and 6 migrations, mojo-flx 23 commits; 372 commits and 27 migrations in
all, the same as on orca 0.3.0. The UI's mojo_history page shows `reads:
mojo.repos` and "Keys From mojo.repos @ 1204299635680259392, Keys 4,
Done 4"; a key's page answers at `/pipelines/mojo_history/keys/sdgunaa%2FMojonet`.

```
$ ./build/orca lineage mojo.commits
mojo.commits@4273895710494911406
made from:
  0 mojo.commits@4273895710494911406 by mojo_history run 3 histories code 0xc80cbd207afece71 from mojo.repos@1204299635680259392
  1 mojo.repos@1204299635680259392 by mojo_repos run 2 find_repos 2024-06-12 code 0xd85f69be3a5160d from gharchive.events@5050756693608396143
  2 gharchive.events@5050756693608396143 by gharchive run 1 load_day 2024-06-12 code 0xc0829dc5610c78ce
made from it:
  nothing
```

`orca backfill mojo_repos 2024-06-12` then queued 0 runs, and `orca
backfill --rerun mojo_repos 2024-06-12` queued run 4, which found the
same 23 candidates already settled. From a plain shell with `CONDA_PREFIX`
unset, `./build/gharchive run --partitions 2024-06-12` (one hour, into a
scratch warehouse) wrote 264,870 events of zstd Parquet, and
`./build/console` served `/`, `/versions`, `/repos/<owner>/<name>` and
their JSON from the lake.
