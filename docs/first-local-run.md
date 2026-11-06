# The first local run, the orca way (orca 0.3.1)

Kept from the census's former GAPS.md: the census run end to end by orca's scheduler on a laptop.


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
