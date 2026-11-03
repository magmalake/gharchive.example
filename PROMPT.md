# The prompt (draft for the getting-started page)

Build me a lake of GitHub activity with magmalake, and an app that shows how
Mojo libraries have grown.

- Make a new pixi project with orca (`pixi shelf add orca-mojo`). Use the
  magmalake skills (orca, dista, magmalake-apps), mojoshelf's skills and
  Modular's mojo-syntax.
- **`gharchive`**: a daily pipeline that imports each day of the GitHub
  Archive (data.gharchive.org, 24 hourly `.json.gz` files) into an Iceberg
  table `gharchive.events` (`id`, `type`, `created_at`, `repo`, `actor`, the
  event's `payload` as JSON), partitioned by day, from 2023-01-01, every day
  at 03:00 UTC for the day before.
- **`mojo_repos`**: a sensor on `gharchive.events` that finds Mojo
  repositories (pushes touching `.mojo` or `.🔥` files, and projects whose
  `pixi.toml` or `mojoproject.toml` names a Mojo package) and keeps them in
  `mojo.repos` (when GitHub says each was created, when it was first seen,
  how it was found, stars, forks, license, default branch, description).
- **`mojo_history`**: keyed by repository, 50 a run, started by new
  repositories: clone each one in a dista task and read its history into
  `mojo.commits` (lines of Mojo at each commit, which tooling the project
  used: none, then magic, then pixi, and the Mojo version its lock file or
  manifest named) and `mojo.migrations` (each change of tooling or Mojo
  version). Versions sort in one order across Modular's renumbering
  (24.x, 25.x, 0.25.x, 0.26.x, 1.x); test that.
- **The console**: a flare app over those tables: the libraries by size and
  age, the Mojo versions they moved to over time, a page per repository.
- Run it locally first on a few hours of the archive. Then deploy it to AWS
  with `orca aws` (on-demand workers, autoscaling from 0), backfill one month
  to see what it costs, then the rest, and serve the console on its own
  hostname. The tables go in the public bucket.
