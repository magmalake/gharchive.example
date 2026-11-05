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

## 20. deflate-mojo can't inflate a stream a window at a time (medium; fixed in deflate-mojo 0.2.0)

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

- **Resolved:** deflate-mojo 0.2.0 has `GzipReader` and `Inflater`
  (`run`/`compact`, input that may still be arriving, CRC-32 and ISIZE
  checked). `src/gzstream.mojo` keeps only the `GzInput` trait and `Whole`;
  the decode loop in `events.decode_gz` runs on `GzipReader`.

## 21. Writing data files on a dista worker: no codec for `DataFile`, no "append these files" in orca (medium; fixed in iceberg-mojo 0.9.1 and orca 0.3.5)

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

- **Resolved:** iceberg-mojo 0.9.1 has `DataFile.encode`/`decode` (the
  `iceberg.wire` codec) and orca 0.3.5 has `orca.tables.DataFiles` (a dista
  `Codec`), `FileWriter`, `write_files` and `append_files`. `src/datafiles.mojo`
  wraps `FileWriter` for the timing and the page-size options, and
  `gharchive` commits with `append_files`.

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

## 23. Writing a batch through iceberg-mojo peaks at ~10x the batch (medium; fixed in iceberg-mojo 0.9.0 with parquet-mojo 0.12.0)

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

## 24. deflate-mojo inflates at ~60% of libdeflate's speed; libdeflate is a candidate backend (medium)

- **Tried:** to make gunzip faster, comparing on one hour (70 MB in,
  491 MB out, M-series Mac) deflate-mojo 0.1.3's `gunzip` (575 ms), this
  app's streaming inflater before and after tuning (380 ms, 331 ms, both
  with the CRC-32, which is ~55 ms of it), zlib 1.3.2's streaming
  `inflate` (445 ms) and libdeflate 1.26's whole-buffer
  `libdeflate_gzip_decompress` (180-225 ms). libdeflate and zlib are
  already in the environment (flare_mlake depends on libdeflate, for gzip
  responses); no magmalake tin wraps libdeflate's decompressor.
- **Happened:** libdeflate is fastest but only decodes a whole buffer into
  a whole buffer: it would bring back the ~500 MB of JSON per hour per
  worker that streaming removed, and the decode couldn't start before the
  download ended. For ~130 ms an hour (about 9% of an hour's CPU here) that
  isn't a clear win, so the app doesn't call it.
- **Did instead:** tuned the app's inflater: one bit-buffer refill per
  symbol with unchecked reads while 8 bytes of input remain, a second
  literal from the same refill, a 10-bit first-level table, Huffman tables
  rebuilt in place rather than allocated per block, and 16-byte match
  copies when the distance allows (380 -> 331 ms an hour).
- **Fix:** deflate-mojo: these decoder changes; and for callers that hold
  the whole output anyway and know its size (Parquet GZIP pages, Avro
  deflate blocks, `gunzip` itself via ISIZE), an optional libdeflate
  backend, or libdeflate's tricks (combined length/extra tables,
  multi-literal decode) in Mojo.

## 25. Overlapping a download with its decode takes a hand-made thread (low)

- **Tried:** to decode each hour while it downloads, so an hour costs
  max(download, decode) instead of their sum (17-29 MB/s from
  data.gharchive.org is 2.2-3.8 s an hour; decoding and writing one is
  now ~1 s).
- **Happened:** flare 0.13.2's `HttpClient.send_streaming` /
  `HttpStreamResponse.read_chunk` stream a body, but a single thread that
  alternates reading and decoding only overlaps as much as the socket
  buffer holds. Nothing in the skills or tins does "read this body on
  another thread into a buffer I can watch": threads-mojo gives
  `ThreadHandle.spawn` over a thin `def(OpaquePtr)` and atomics, so the
  shared state is a heap struct by address. `read_chunk` returns a new
  `List` per call, which is then copied into the buffer.
- **Did instead:** `fetch.Download`: the response moves to a heap
  `_Shared` with a buffer sized from `Content-Length`; a reader thread
  copies chunks in and release-stores how much has arrived; the task's
  thread inflates what is there (the inflater rolls back a block that
  outruns it) and polls when it needs more. Without `Content-Length` the
  body is read whole first. At 25 MB/s per connection, six hours: PARALLEL=1
  23.8 -> 17.2 s (the downloads alone are ~16.8 s), PARALLEL=4 8.0 -> 5.7 s.
- **Fix:** flare: `read_chunk_into(buf, at)` (no allocation per chunk),
  and a `Body` that fills a buffer on its own thread with `available()` /
  `wait(n)`; threads-mojo: a typed `spawn` over an owned value, as
  `TypedPool` does for pools.

## 26. A rerun of an appending step appends again; orca.tables can't replace a partition (high)

- **Tried:** `orca backfill --rerun gharchive 2026-10-13` (on AWS, to
  reload a day), and, for the new pipelines, a way to make a rerun of a
  day or a key leave one copy of its rows.
- **Happened:** `gharchive.events` had 2026-10-13 twice: runs 48 and 133
  each appended 2,029,814 rows. `load_day` skips the hours *its own run*
  committed (`find_commit` matches this run's commits only), so a new run
  appends every hour again. The orca skill and DESIGN.md say "a partition
  that's done is not protected ... its steps append again", but nothing
  in `orca.tables` replaces a partition: there is `append`,
  `append_files` and `commit(FileChanges)`, and finding a partition's
  files is up to the caller. iceberg-mojo's `Table.overwrite` and
  `dynamic_partition_overwrite` exist, but bypass orca's commit
  bookkeeping and fencing.
- **Did instead:** `tools/drop_run.mojo` removed run 133's 48 files (one
  `delete` snapshot, with `orca.partitions` in its summary for the
  sensors). `src/replace.mojo`: `partition_files` (plan the current
  snapshot, keep the files whose first partition value is wanted) and
  `replace_files` (one `commit(ctx, t, "overwrite", FileChanges)` that
  removes them and adds the new rows, `append` when nothing is removed,
  `find_commit` first). gharchive's first hour of a new run is now an
  overwrite of the day's files; mojo_activity, mojo_stats read the month
  partitions they touch, keep the rows they didn't recompute and replace
  the rest. mojo_history's writes are idempotent per repository instead
  (it skips what each table already has).
- **Fix:** orca: `replace_partitions(ctx, table, batches_or_files)` (an
  overwrite of exactly the partitions the new rows land in, through
  orca's commit), and a `Step[..., replace=True]` that makes a new run's
  first commit to a table replace the run's partitions; until then
  `orca backfill --rerun` should warn for a step that appends.
  [magmalake/orca.mojo issue](https://github.com/magmalake/orca.mojo/issues/120).

## 27. Snapshot expiry is quadratic, and commits slow down with every metadata file (medium; fixed in iceberg-mojo 0.10.0 and orca 0.4.0)

- **Tried:** to expire `gharchive.events`' old snapshots (888 of them, a
  937 KB `metadata.json` rewritten on every commit), or to have iceberg-mojo
  delete old metadata files with `write.metadata.delete-after-commit.enabled`
  and `write.metadata.previous-versions-max`.
- **Happened:** iceberg-mojo 0.9.1 has `Table.expire_snapshots` and
  `maintain.expire_snapshots`, but they read every retained snapshot's
  manifest list and then every manifest it lists, with no cache, so a
  table with one manifest per commit costs snapshots x manifests reads
  (~600,000 S3 GETs here), and membership is a linear scan of a `List`.
  The two metadata properties aren't read at all ("a separate policy",
  says `maintain.mojo`), and `commit_metadata` lists the whole metadata
  directory to find the latest file (889 objects, a page of
  `ListObjectsV2` per 1,000) on every commit.
- **Did instead:** nothing: no expiry is wired in yet.
- **Fix:** iceberg-mojo: cache manifests by path in `_referenced_by` (a
  manifest is read once however many snapshots list it) and keep the keep
  set in a `Dict`; honour `write.metadata.delete-after-commit.enabled`
  with `previous-versions-max`; use `version-hint.text` before listing.
  orca: an `expire_snapshots(ctx, table, older_than_days)` step helper
  that refuses snapshots a live run has pinned.
- **Fixed:** iceberg-mojo 0.10.0 expires in linear time: each manifest
  list is read once (batched), only manifests that no retained snapshot
  lists are opened, and their files are checked only against the retained
  manifests a rewrite could have carried them into (591,513 reads and 57 s
  on a local 1,000-snapshot table become 1,097 reads and 0.27 s). Retention
  follows the spec (per-branch `min-snapshots-to-keep`, age, tags,
  `max-ref-age-ms`, the `history.expire.*` properties).
  `write.metadata.previous-versions-max` and
  `write.metadata.delete-after-commit.enabled` are honoured. A commit no
  longer lists `metadata/`: it does one prefix listing for the version it
  writes and reads `version-hint.text`. Appends fold small manifests
  (merge-append), so the manifest list stops growing by one entry per
  commit. orca 0.4.0 gives every table delete-after-commit, a hundred
  previous versions and thirty days of history (`ensure_table(...,
  properties=)` overrides them; gharchive.events keeps seven days). It has
  `orca expire <dataset>|--all` and a daily sweep in the scheduler, both
  through `bin/orca_maintain.mojo`. They keep the snapshots that runs which
  can still resume read or committed, and the last run's commits.
  mojo_activity's `_loaded_days` reads the pinned snapshot's partitions
  instead of walking the snapshot history, which expiry now cuts.

## 28. Removing files reads every manifest, even of other partitions (low)

- **Tried:** gharchive's overwrite of one day in a table of 888 manifests.
- **Happened:** `prepare_commit`'s `_carry_or_rewrite` opens every
  carried manifest to look for the removed paths, without its partition
  summary, so replacing one day reads all of them (888 small GETs).
- **Did instead:** accepted it: a rerun of a day is rare.
- **Fix:** iceberg-mojo: skip a manifest whose partition summaries can't
  hold any removed file's partition (the removed files' partitions are
  known from the plan that found them).

## 29. Two writers replacing the same partition: orca's commit retry replays a stale overwrite (medium)

- **Tried:** a second pipeline (keyed on `mojo.repos`) to fill the history
  of newly found repositories into `mojo.activity`, beside the daily one.
- **Happened:** a replace reads the partition's files, then commits
  `FileChanges(removed=...)`. When another writer commits in between,
  `orca.tables.commit` reloads and retries with the same `FileChanges`;
  `prepare_commit` raises only when *none* of the removed files is
  current, so a partly stale overwrite commits and both writers' rows
  stay. orca's "one live run per partition" holds within a pipeline only.
- **Did instead:** one writer: mojo_activity catches new repositories up
  itself (`mojo.activity_repos` says which are), and runs one run at a
  time (`max_runs=1`).
- **Fix:** iceberg-mojo: `prepare_commit` refuses (`validate`) a removal
  of files that aren't all current, as Java's `validateNoConflictingData`
  does; orca: a commit retry that rebuilds its `FileChanges` through a
  callback, or that fails the attempt so the step recomputes.

## 30. A sensor's snapshot that arrives during a live run of its partition is dropped (medium)

- **Tried:** mojo_activity as a sensor on `mojo.repos`, so the snapshot
  mojo_repos commits for a day reruns that day's activity with the new
  repositories.
- **Happened:** gharchive's commit starts mojo_repos and mojo_activity for
  the day at the same time; when mojo_repos commits, mojo_activity's run
  for that day can still be live, pinned to the `mojo.repos`
  before it, and "a sensor leaves those keys to it", so the new snapshot
  starts nothing. The new repositories wait for the next run (the next
  day, at most).
- **Did instead:** accepted the delay: any later run catches up every
  member not in `mojo.activity_repos`.
- **Fix:** orca: queue the keys again behind a live run when the live run
  pinned an older snapshot of the sensed dataset than the one that
  arrived.

## 31. No weekly partitions; list columns take another batch API (low)

- **Tried:** a weekly refresh (`mojo_stats`) and a `topics` list column.
- **Happened:** orca has `Daily` and `Monthly` only. A `list<string>`
  column can't go through `ColumnBuilder`/`batch_of`: it takes
  `NestedBuilder` (one JSON cell per row), `ColumnTree` from
  `iceberg.nested` (not exported from `iceberg.batch`) and
  `batch_of_columns`; reading one back means following
  `batch.arena.nodes[a.children[0]]` by the list's offsets.
- **Did instead:** `Daily["2026-11-01"]` with `Cron["0 6 * * 1"]` and
  `fills=Current`; `lake.json_strings` and `cols.strs_at`.
- **Fix:** orca: `Weekly[start]` (ISO weeks); iceberg-mojo:
  `ColumnBuilder.add_strings(List[String])` for lists of primitives and a
  `list_at` reader, and `ColumnTree` exported beside `batch_of_columns`.

---

## 32. A snapshot needs a data file, so an empty hour needs a marker row (low)

- **Tried:** gharchive's hour tasks write `gharchive.candidates` and
  `gharchive.releases` beside the events, and an hour can have no candidates.
  `orca.tables.append_files` documents that "no files commits an empty
  snapshot", which keeps a table's commits numbered one a step's hour.
- **Happened:** `iceberg.prepare_append` and `prepare_commit` both raise "an
  append needs at least one data file" / "a commit must add or remove at
  least one file", and `write_data_files` skips a batch with no rows, so an
  empty hour can't be committed at all.
- **Did instead:** an hour with nothing for a table writes one row for no
  repository (`repo = ""`, reason `hour`), which nothing matches
  (`hourindex.HourIndex.marker`).
- **Fix:** iceberg should commit an empty append (a snapshot with no
  manifest), or write a zero-row file; orca's docstring says it can.
- **Since:** gharchive commits its index tables once a day, not an hour, so
  only a day with nothing at all for a table needs the marker (one row, for
  the day's first hour); gharchive_index still commits an hour at a time and
  keeps one per empty hour.

## 33. A repository found later needs every repository's history, so the index is big (medium)

- **Tried:** mojo_activity re-read a whole day of events (about 45 s) per
  loaded day for each repository found after the days were loaded.
- **Did instead:** gharchive's hour tasks also write `gharchive.repo_hour`:
  one row per (repository, actor, hour) for **every** repository (about one
  row per two events, 100K an hour in 2023), sorted by repository in 16K-row
  row groups, because only a candidate can enter `mojo.repos` but which one
  isn't known until a later day; a day's catch-up scan is then `repo in
  (...)` plus a day range, reading a few row groups of each hour's file.
  mojo_activity's catch-up still makes a dista task per loaded day (24 small
  files each); it no longer reads event bytes.
- **Since:** the three index tables are committed once a day by gharchive
  (24 hours' files in one snapshot, instead of 24 snapshots): 4 commits per
  hour cost ~1.7 s on AWS, ~41 s of an ~81 s day, serially. The files stay
  one per hour; the commits are not concurrent (a `Ctx` and its commit
  numbering aren't thread-safe).
- **Fix:** a daily compaction of `gharchive.repo_hour` into one file per
  day (or `bucket[N](repo)` partitions) would cut a catch-up from 24 file
  opens per day to one, and iceberg's `in` on a bucketed column would prune
  the files before opening them.

## 34. `bazel` as tooling, and rewriting histories already read (low)

- `history.tooling` ranks `bazel` (a root `MODULE.bazel`, `WORKSPACE`,
  `WORKSPACE.bazel` or `BUILD.bazel`) above pixi, magic and none.
  mojo_history skips repositories it has read, so `mojo_retool` re-reads
  them and replaces their rows in `mojo.commits`, `mojo.migrations` and
  `mojo.tags` with one `overwrite` snapshot a table. There is no row-level
  delete or update in the writers used here, so the rows of the other
  repositories are read and written again.

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
