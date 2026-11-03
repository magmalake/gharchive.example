# Gaps found while building gharchive.example

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

## 2. A pipeline binary run outside `pixi run` aborts in zstd with a misleading path (high)

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

## 5. deflate-mojo is raw DEFLATE only; there's no gzip (low)

- **Tried:** to decompress GH Archive's `.json.gz` with a tin.
- **Happened:** `deflate-mojo` is raw RFC 1951 by design ("Raw means raw");
  no tin reads gzip framing. zstd/brotli/lz4/snappy don't help.
- **Did instead:** `src/gz.mojo`, 40 lines: the RFC 1952 header, `inflate_at`,
  the 8-byte trailer, and concatenated members. It does 690 MB of JSON in
  0.8 s on an M-series Mac, so speed is fine.
- **Fix:** add `gunzip` / `gzip` to deflate-mojo (or a `gzip-mojo` tin) and
  list it in mojoshelf; mojo-data-performance's readers-and-codecs could
  mention it.

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
