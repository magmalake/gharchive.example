# mojo-census

A lake of GitHub activity built on [magmalake](https://magmalake.org), and
a console that shows how Mojo repos have grown. Everything is Mojo, in
one pixi project: five [orca](https://github.com/magmalake/orca.mojo)
pipelines write Iceberg tables, the project's own `orca` schedules them,
and a [flare](https://github.com/magmalake/flare_mlake) app reads the
tables.

It runs on AWS: the console is at <https://census.mlake.dev>, and orca's UI,
with every run, log and table, at <https://orca.mlake.dev>. The
[getting-started guide](https://mlake.dev/getting-started/) builds it two
ways, with an agent from [PROMPT.md](PROMPT.md) or step by step.

```
GH Archive ──gharchive──▶ gharchive.events ──mojo_repos──▶ mojo.repos ─┬──────────┐
 (daily, 03:00 UTC,         (by day)    │    (sensor on    mojo.checked │          │
                            + .candidates,  │    .candidates)                │          │
                            .repo_hour,     │                                │          │
                            .releases       │                                │          │
  a dista task per hour)                │                               │          │
                                        └──mojo_activity──▶ mojo.activity          │
                                           (sensor on both; mojo.releases          │
                                            a dista task    mojo.activity_repos    │
                                            per day read)        (by month)        │
                            mojo.commits ◀──mojo_history───────────────────────────┤
                            mojo.migrations  (keyed by repository, 50 a run,       │
                            mojo.tags         a dista task per clone)              │
                            mojo.repo_stats ◀──mojo_stats──────────────────────────┘
                              (by month)       (Mondays 06:00 UTC, GitHub API)
                                   │
                                   ▼
                          bin/console (flare)
```

- **`pipelines/gharchive.mojo`**: each day of [GH Archive](https://www.gharchive.org/)
  from 2023-01-01, at 03:00 UTC for the day before, into `gharchive.events`
  (`id`, `type`, `created_at`, `repo`, `actor`, `payload` as JSON text),
  partitioned by day. A day's hours are dista tasks: each streams its
  hour in on a reader thread while it gunzips and parses what has
  arrived, a window at a time, and writes the Parquet files on the worker
  (a 50,000-row file at a time, sorted by repository and type, in 16 MB row
  groups, so an hour in flight takes about 450 MB:
  `tools/hour_memory.mojo` measures it); the step commits each hour's files
  to the events as one append, in order, and a retry skips the hours already
  committed. A new run of a day that has rows (`orca backfill --rerun`)
  replaces them: its first hour's commit removes the day's earlier files.
  While an hour's task parses its events it also builds three small tables'
  rows: `gharchive.candidates` (one row per repository, hour and reason: the
  `detect.scan_event` rules below), `gharchive.repo_hour` (the counts
  `mojo.activity` needs, per repository, actor and hour, of **every**
  repository: about 100K rows an hour, sorted, so a repository found later
  has its whole history without reading events again) and `gharchive.releases`
  (published ReleaseEvents). The step keeps those files and commits each of
  the three tables **once a day**, at the end, with all the hours' files (the
  day's first commit to each replaces the day's earlier files, as for the
  events). That is one snapshot a table instead of 24, which took about 40 s
  of a day's 80. A retry that skips hours of events committed by the failed
  attempt builds their rows again from `gharchive.events` (the code
  gharchive_index uses), and finds the day's index commits if the attempt
  made them, so they aren't made twice. A day with no rows at all for a
  table gets one row for no repository (`repo = ""`), since a snapshot needs
  a data file.
- **`pipelines/gharchive_index.mojo`**: a one-off that fills those three
  tables for days loaded before gharchive wrote them, reading each hour of
  `gharchive.events` once (`orca backfill gharchive_index <days>`).
- **`pipelines/mojo_repos.mojo`**: a sensor on `gharchive.candidates`. For each
  day it reads the candidates (repository names, the `language` of repository
  objects that pull-request and fork payloads embed, commit messages
  naming `.mojo`/`.🔥` files or `mojoproject.toml`) and checks them with
  GitHub (`language: Mojo`, a `pixi.toml` or `mojoproject.toml` naming a
  Mojo package, or the pushed commit's files). Mojo repositories go into
  `mojo.repos` (created, first seen, how found, stars, forks, license,
  default branch, description, size, topics); every answer goes into
  `mojo.checked`, so a repository is asked about once. Forks are left out.
- **`pipelines/mojo_history.mojo`**: keyed by repository (the `repo`
  column of `mojo.repos`, `owner/name`), 50 a run, and a sensor on
  `mojo.repos`: each snapshot mojo_repos commits starts runs for the
  repositories it adds. Each repository is cloned in a
  dista task and its first-parent history read into `mojo.commits` (lines
  and files of Mojo at each commit, the tooling, none → magic → pixi → bazel, and
  the Mojo version the lock file or manifest names), `mojo.migrations`
  (each change of tooling or Mojo version) and `mojo.tags` (each git tag:
  the commit, annotated or not, its date, and the tooling and Mojo version
  at that commit). A repository already in a table isn't written to it
  again; one with a history and no tags is cloned without file contents
  for its tags only, so `orca backfill --rerun mojo_history @all` fills
  `mojo.tags` for repositories read before tags were.
- **`pipelines/mojo_retool.mojo`**: a one-off that re-reads the histories
  mojo_history already read and replaces their rows (used when `tooling`
  learned `bazel`, a root `MODULE.bazel`/`WORKSPACE`/`BUILD.bazel`, which
  outranks pixi: `orca backfill --rerun mojo_retool @all`).
- **`pipelines/mojo_versions.mojo`**: keyed by repository like mojo_history
  (50 a run, a sensor on `mojo.repos`), for the repositories whose lock file
  and manifest name no Mojo version (early projects, installed with `modular
  install mojo` before magic and pixi: 105 of 211 in 2026-11). Each is
  cloned without file contents and its HEAD read for a version: lock file,
  manifest (also `pyproject.toml`, `requirements.txt`), a version file,
  CI workflows, Dockerfiles and dev containers, README, in that order of
  precedence (`versions.mojo`: `script_version`, `readme_version`,
  `pick_version`); `modular/modular` states its own in `Mojo/pixi.lock`.
  `mojo.repo_versions` has one row each: the version and its source (`lock`,
  `manifest`, `file`, `ci`, `docker`, `readme`, `repo`) and the file, and
  apart from them the release current at the last commit that touched a
  Mojo file (`version_estimate`, source `date`, from the table in
  `mojo_releases.mojo`). Rows are replaced like mojo_retool's, so
  `orca backfill --rerun mojo_versions @all` fills the repositories already
  in the lake and a rerun gives the same rows. The console shows the
  detected version with its source ("24.4, from CI"), `no-manifest` apart
  from `unknown`, and the estimate as "~24.3 by date" (the Overview's donuts
  and `/repos?version=` count it with `?estimate=1`, off by default).
  `tools/head_versions.mojo` tries the readers on named repositories.
- **`pipelines/mojo_activity.mojo`**: daily, a sensor on
  `gharchive.repo_hour`, `gharchive.releases` and `mojo.repos`, no API calls
  and no event bytes. For each day, every repository in
  `mojo.repos`: `mojo.activity` (events, stars as WatchEvents, forks,
  published releases, issues and pull requests opened, pushes, distinct
  actors) and `mojo.releases` (tag, name, published, prerelease), both by
  month. A repository not yet in `mojo.activity_repos` is caught up: the
  run also reads every other day `gharchive.repo_hour` has (from the day the
  repository was created) for it, a dista task a day, so a repository
  found today has its whole history. A run replaces the rows of the
  (repository, day) pairs it computed and keeps the rest, one run at a
  time, so reruns don't duplicate rows.
- **`pipelines/mojo_stats.mojo`**: Mondays at 06:00 UTC (daily partitions,
  one a week), one `GET /repos/{owner}/{repo}` per repository in
  `mojo.repos` into `mojo.repo_stats` (stars, forks, open issues, watchers,
  topics, archived, last push, homepage, license, description, size), by
  month of `as_of`, so stars become a time series. A repository that is
  gone, blocked or renamed is a row with that `state`; a rate limit is
  waited out by `Retry-After` / `X-RateLimit-Reset`. A rerun of a day
  replaces that day's rows.
- **`bin/console.mojo`**: an overview (`/`: repos, commits and lines of
  Mojo with their change over 30 days, repos per Mojo version family,
  monthly curves from `mojo.commits`, adoption of the newest version,
  tooling share, the repos rising in stars), the repos by size and age
  (`/repos`, sortable by lines, files or stars with `?sort=`, filterable
  with `?version=1.x` and `?active=1y`), search by name, topic or
  description (`/search`), the Mojo versions they moved to over time
  (`/migrations`), and a page per repository (`/repos/<owner>/<name>`:
  current stars, forks and topics from the latest `mojo.repo_stats` row,
  stars per month from `mojo.activity`, releases and tags), each also as
  JSON under `/api/` (`/api/overview`, `/api/repos`, ...). The repos and
  the overview are computed once and kept in memory; the tables' current
  snapshots are checked every five minutes and everything is read again
  only when one moved.
- **`src/`**: the tables (`lake.mojo`), the JSON scanner, HTTP, detection, git history, and `versions.mojo`, which orders Mojo versions
  across Modular's renumbering (24.x, 25.x, 0.25.x, 0.26.x, 1.x);
  `tests/test_versions.mojo` tests that order. `activity.mojo` counts a
  day's events, `stats.mojo` reads GitHub's repository JSON, and
  `replace.mojo` replaces a table's rows by partition. `overview.mojo` computes the
  Overview's numbers, `listing.mojo` the Repos table's sorting and filters,
  and `charts.mojo` draws the SVG charts.
- **`tools/drop_run.mojo`**: removes the rows one orca run appended to one
  partition (how 2026-10-13, loaded twice before gharchive replaced a
  rerun's day, was repaired).

What the magmalake libraries were missing while this was built is tracked as
GitHub issues in each library's repository (orca.mojo, iceberg.mojo,
dista.mojo, json_mlake, flare_mlake, deflate.mojo, threads.mojo, and mojoshelf);
the census's own open work is in [this repository's issues](https://github.com/magmalake/mojo-census/issues).

## Run it locally

[Develop locally](https://mlake.dev/getting-started/develop) on mlake.dev
covers this section with timings, what needs the network, and how to try a
change to orca, iceberg or parquet in the census before it is released. It
builds for macOS arm64 and linux-aarch64 (`pixi.toml`'s platforms); there is
no linux-64 build. The first `pixi run build` compiles every dependency and
takes about nine minutes and 19 GB under `.pixi` (`.pixi/bld`, 18 GB of it, is
build scratch).

You need [pixi](https://pixi.sh) and the mojoshelf CLI (`pixi global install
--channel https://mojoshelf.org/channel mojoshelf`). Build inside the pixi
environment; the built binaries also run from a plain shell (since
zstd-mojo 0.1.5 they find their shared libraries without `CONDA_PREFIX`),
though Postgres and `git` come from the pixi environment.

```sh
pixi run build      # build/orca, build/{gharchive,mojo_repos,mojo_history,mojo_activity,mojo_stats}, build/console
pixi run test       # version ordering, history and tag parsing, events, activity, GitHub stats
```

### The console on the deployed data

The quickest way to try a console change: build it and point it at the
warehouse the AWS pipelines write. It only reads. The S3 client takes
credentials from the environment, so export your AWS login first:

```sh
pixi run build-console
eval "$(aws configure export-credentials --profile <profile> --format env)"
export AWS_REGION=us-east-2
ORCA_WAREHOUSE=s3://mlake-public-617847241090/warehouse PORT=8080 pixi run ./build/console
```

### The pipelines on their own

`pixi run test-daily` (network, three hours of GH Archive, about 50 seconds)
checks gharchive's day commits against a gharchive that commits an hour at a
time, through a failed-and-retried step and a rerun (`scripts/test-daily.sh`).
It needs that older build as `build/gharchive-main`, and `origin/main` no
longer is one (it already commits daily, and the check fails with "old
gharchive.candidates: not three snapshots"). Build the commit before the
change:

```sh
mkdir -p build/main-src && git archive 8922605~1 | tar -x -C build/main-src
pixi run mojo build -I build/main-src/src build/main-src/pipelines/gharchive.mojo -o build/gharchive-main
pixi run test-daily
```

No database needed; `GHARCHIVE_HOURS` keeps the download to two hourly files
(about 100 MB each):

```sh
export ORCA_WAREHOUSE=$PWD/build/warehouse
GHARCHIVE_HOURS=15,17 pixi run ./build/gharchive run --partitions 2024-06-12
pixi run ./build/mojo_repos run --partitions 2024-06-12
MOJO_HISTORY_MAX_KB=100000 pixi run ./build/mojo_history run --partitions @all
pixi run ./build/mojo_activity run --partitions 2024-06-12
pixi run ./build/mojo_versions run --partitions @all
pixi run ./build/mojo_stats run --partitions $(date +%F)   # GITHUB_TOKEN helps
PORT=8080 pixi run ./build/console      # http://127.0.0.1:8080
```

mojo_stats takes today's date: its partitions start on 2026-11-01, and a
date before that is refused. Without a token mojo_repos checks 25 candidates
a run (1000 with `GITHUB_TOKEN`). The whole sequence takes about 40 seconds
once the download is under way.

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
snapshots made after it is registered; if you ran the pipelines on their own
above, delete `build/warehouse` first), then backfill one day:

```sh
pixi shell
. scripts/env.sh
for p in gharchive mojo_repos mojo_history mojo_activity mojo_stats; do ./build/orca locate build/$p --root .; done
./build/orca register ./build/gharchive ./build/mojo_repos ./build/mojo_history ./build/mojo_activity ./build/mojo_stats
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

### Registering on the server

`orca.toml` at the repository root says how each scheduled pipeline runs
(`max_runs`, fills, `DISTA_WORKER_SLOTS`, secrets), each setting with a
comment. `Dockerfile.orca` puts it in the image at `/opt/orca/orca.toml`
(`ORCA_CONFIG`), next to the pipelines (`ORCA_PIPELINES_DIR`), so on the
server registering is `docker exec scheduler orca register` (orca after
0.10.0). To change a setting: edit `orca.toml`, merge, deploy the new image,
register again. `mojo_retool` is a one-off and isn't in the file.

### What a local run produced

On 2024-06-12, hours 15 and 17: 476,227 events (154 MB of Parquet), 23
candidates, 4 Mojo repositories (NuMojo, Mojonet, mojo-flx and
modular/modular, which was skipped for size), 3 histories read, 372
commits and 27 migrations. [docs/first-local-run.md](docs/first-local-run.md)
has the run as the scheduler did it, on orca 0.3.1.

## Table history

Every table keeps thirty days of snapshots (orca's default) and
`gharchive.events` a week (`lake.events_properties`, 168 hourly commits);
each commit deletes the metadata files beyond the last hundred. The
scheduler expires every table by that policy once a day through
`build/orca_maintain` (`bin/orca_maintain.mojo`, built by `pixi run build`
beside `orca`), keeping whatever a run that can still resume read or
committed, and the last run's snapshots. By hand:

```
./build/orca expire gharchive.events --older-than 7d --dry-run --report
./build/orca expire --all          # each table by its own policy
```

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
- `mojo.repos` stars and forks are as of the day a repository was found;
  `mojo.repo_stats` has them week by week, and `mojo.activity` day by day
  from GH Archive.
