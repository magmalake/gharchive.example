# gharchive.example

A lake of GitHub activity built on [magmalake](https://magmalake.org), and
a console that shows how Mojo libraries have grown. Everything is Mojo, in
one pixi project: three [orca](https://github.com/magmalake/orca.mojo)
pipelines write Iceberg tables, the project's own `orca` schedules them,
and a [flare](https://github.com/magmalake/flare_mlake) app reads the
tables.

It runs on AWS: the console is at <https://census.mlake.dev>, and orca's UI,
with every run, log and table, at <https://orca.mlake.dev>. The
[getting-started guide](https://mlake.dev/getting-started/) builds it two
ways, with an agent from [PROMPT.md](PROMPT.md) or step by step.

```
GH Archive ──gharchive──▶ gharchive.events ──mojo_repos──▶ mojo.repos ─┐
 (daily, 03:00 UTC,         (by day)         (sensor)      mojo.checked │
  a dista task per hour)                                               │
                            mojo.commits ◀──mojo_history──────────────┘
                            mojo.migrations  (keyed by repository, 50 a run,
                                              a dista task per clone)
                                   │
                                   ▼
                          bin/console (flare)
```

- **`pipelines/gharchive.mojo`**: each day of [GH Archive](https://www.gharchive.org/)
  from 2023-01-01, at 03:00 UTC for the day before, into `gharchive.events`
  (`id`, `type`, `created_at`, `repo`, `actor`, `payload` as JSON text),
  partitioned by day. A day's hours are dista tasks (download, gunzip,
  parse); each hour is appended as it arrives, so a day never sits in memory
  whole, and a retry skips the hours already committed.
- **`pipelines/mojo_repos.mojo`**: a sensor on `gharchive.events`. For each
  day it finds candidates (repository names, the `language` of repository
  objects that pull-request and fork payloads embed, commit messages
  naming `.mojo`/`.🔥` files or `mojoproject.toml`) and checks them with
  GitHub (`language: Mojo`, a `pixi.toml` or `mojoproject.toml` naming a
  Mojo package, or the pushed commit's files). Mojo repositories go into
  `mojo.repos` (created, first seen, how found, stars, forks, license,
  default branch, description, size); every answer goes into
  `mojo.checked`, so a repository is asked about once. Forks are left out.
- **`pipelines/mojo_history.mojo`**: keyed by repository (the `repo`
  column of `mojo.repos`, `owner/name`), 50 a run, and a sensor on
  `mojo.repos`: each snapshot mojo_repos commits starts runs for the
  repositories it adds. Each repository is cloned in a
  dista task and its first-parent history read into `mojo.commits` (lines
  and files of Mojo at each commit, the tooling, none → magic → pixi, and
  the Mojo version the lock file or manifest names) and `mojo.migrations`
  (each change of tooling or Mojo version).
- **`bin/console.mojo`**: the libraries by size and age (`/`), the Mojo
  versions they moved to over time (`/versions`), and a page per
  repository (`/repos/<owner>/<name>`), each also as JSON under `/api/`.
- **`src/`**: the tables (`lake.mojo`), the JSON scanner, HTTP, detection, git history, and `versions.mojo`, which orders Mojo versions
  across Modular's renumbering (24.x, 25.x, 0.25.x, 0.26.x, 1.x);
  `tests/test_versions.mojo` tests that order.

[GAPS.md](GAPS.md) lists what the magmalake skills and libraries were missing
while this was built.

## Run it locally

You need [pixi](https://pixi.sh) and the mojoshelf CLI (`pixi global install
--channel https://mojoshelf.org/channel mojoshelf`). Build inside the pixi
environment; the built binaries also run from a plain shell (since
zstd-mojo 0.1.5 they find their shared libraries without `CONDA_PREFIX`),
though Postgres and `git` come from the pixi environment.

```sh
pixi run build      # build/orca, build/{gharchive,mojo_repos,mojo_history}, build/console
pixi run test       # version ordering and history parsing
```

### The pipelines on their own

No database needed; `GHARCHIVE_HOURS` keeps the download to two hourly files
(about 100 MB each):

```sh
export ORCA_WAREHOUSE=$PWD/build/warehouse
GHARCHIVE_HOURS=15,17 pixi run ./build/gharchive run --partitions 2024-06-12
pixi run ./build/mojo_repos run --partitions 2024-06-12
MOJO_HISTORY_MAX_KB=100000 pixi run ./build/mojo_history run --partitions @all
PORT=8080 pixi run ./build/console      # http://127.0.0.1:8080
```

### The orca way: Postgres, the scheduler and the UI

A Postgres that lasts between sessions, under `build/` (from conda-forge's
`postgresql`, in `pixi.toml`):

```sh
pixi run initdb -D build/pg --auth=trust --username=postgres -E UTF8 --locale=C
pixi run pg_ctl -D build/pg -l build/pg.log -o "-k $PWD/build -c listen_addresses=" -w start
pixi run createdb -h "$PWD/build" -U postgres orca
```

`scripts/env.sh` sets `ORCA_DATABASE_URL` to it, the warehouse and logs
under `build/`, `GHARCHIVE_HOURS=15,17`, `MOJO_HISTORY_MAX_KB=100000` (skips
modular/modular, which is over a gigabyte) and a 10-second sense interval.
Register the pipelines **before** loading data (a sensor only counts
snapshots made after it is registered), then backfill one day:

```sh
pixi shell
. scripts/env.sh
for p in gharchive mojo_repos mojo_history; do ./build/orca locate build/$p --root .; done
./build/orca register ./build/gharchive ./build/mojo_repos ./build/mojo_history
./build/orca scheduler &                 # fires, senses, starts runs
./build/orca ui &                        # http://127.0.0.1:8270
./build/orca backfill gharchive 2024-06-12
```

The scheduler then runs gharchive for the day, which starts mojo_repos for
the same day (sensor), whose snapshot of `mojo.repos` starts mojo_history
for the repositories it added (keyed sensor). Watch it in the UI or in
`build/logs/<pipeline>/<run>/`. If port 8270 is taken (another orca UI),
start the UI with `ORCA_UI_ADDR=127.0.0.1:8275`. `./build/orca lineage
mojo.commits` traces the histories back to the `gharchive.events` snapshot
and run they came from.
`scripts/with-postgres.sh` (from orca) runs a command against a throwaway
server instead.

Without a token, GitHub allows 60 API requests an hour, and mojo_repos
spends one to three per candidate; a day with more candidates than that
leaves the rest as `unchecked` in `mojo.checked`, and the next run checks
them first. To check them for that day once the limit has reset (an hour
later), re-run the day, which already succeeded:

```sh
./build/orca backfill --rerun mojo_repos 2024-06-12
```

Set `GITHUB_TOKEN` to lift the limit. Stop everything with
`kill` on the scheduler's and UI's PIDs and `pg_ctl -D build/pg stop`.

### What a local run produced

On 2024-06-12, hours 15 and 17: 476,227 events (154 MB of Parquet), 23
candidates, 4 Mojo repositories (NuMojo, Mojonet, mojo-flx and
modular/modular, which was skipped for size), 3 histories read, 372
commits and 27 migrations. The end of [GAPS.md](GAPS.md) has the run as the
scheduler did it, on orca 0.3.1.

## What's left for AWS

Not done in this local run:

- `orca aws up` (stack, hostnames for the UI and the console, Budgets
  email), `orca aws push` (the linux-aarch64 image; `pixi.toml` already has
  the platform, `postgresql` and `git`), `orca aws register --workers 0..4
  gharchive mojo_repos mojo_history`, `orca aws app console`.
- A `GITHUB_TOKEN` in Secrets Manager (`orca/github-token`) registered with
  `--secret GITHUB_TOKEN=orca/github-token` for mojo_repos; with it the
  check budget is 1000 a run. GitHub code search (finding `pixi.toml`s that
  name Mojo directly) needs a token and isn't used.
- Unset `GHARCHIVE_HOURS` and `MOJO_HISTORY_MAX_KB` on AWS (all 24 hours,
  every repository); check the size of a day's run instance, since the
  history step holds 50 repositories' rows and modular/modular is large.
- Backfill one month (`./build/orca aws ...` then `orca backfill gharchive
  2025-01-01..2025-01-31`) to see the cost, then the rest from 2023-01-01.
  Note that recent hours of GH Archive carry much smaller payloads.
- Re-running a day appends its events again (no overwrite of a day's
  partition yet), and `mojo.repos` stars and forks are as of the day a
  repository was found; refreshing them needs an overwrite.
