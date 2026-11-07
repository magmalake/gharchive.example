"""The dependencies manifests declare, and resolving them to census repos.

    pixi run test
"""

from std.testing import TestSuite, assert_equal, assert_true

from deps import (
    DEPENDS,
    PROVIDES,
    Dep,
    RepoDep,
    declared_count,
    decode_deps,
    dedupe,
    encode_deps,
    github_repo,
    is_recipe,
    manifest_deps,
    norm_name,
    resolve,
)


def _find(rows: List[Dep], relation: String, name: String, section: String = "") -> Int:
    """The index of the first row with `relation` and `name` (and `section`
    when given), or -1."""
    for i in range(len(rows)):
        if rows[i].relation == relation and rows[i].name == name:
            if section.byte_length() == 0 or rows[i].section == section:
                return i
    return -1


comptime PIXI_BUILD = """[workspace]
authors = ["Mikhail Tavarez <miktavarez@gmail.com>"]
channels = ["conda-forge", "https://conda.modular.com/max"]
platforms = ["osx-arm64", "linux-64", "linux-aarch64"]
license = "MIT"
preview = ["pixi-build"]

[tasks]
tests = "sh -c 'for f in test/*.mojo; do mojo -I . $f; done'"
format = [{ task = "mojo_format" }]

[package]
name = "floki"
version = "0.4.1"

[package.build]
backend = { name = "pixi-build-mojo", version = "0.*", channels = [
  "https://prefix.dev/pixi-build-backends",
  "https://prefix.dev/conda-forge",
]}

[package.build.config.pkg]
name = "floki_pkg"

[dependencies]
mojo = ">=1.1.0,<1.2.0"
emberjson = { git = "https://github.com/bgreni/EmberJson.git", tag = "0.4.0" }
mojo-curl = { git = "https://github.com/thatstoasty/mojo-curl.git", tag = "v0.4.6" }
curl_wrapper = { git = "https://github.com/thatstoasty/mojo-curl.git", subdirectory = "shim", tag = "v0.4.6"  }
# mojo_datetime = { git = "https://github.com/martinvuyk/forge-tools.git" }
small_time = ">=26.2.0,<26.3"  # a comment

[package.run-dependencies]
mojo-compiler = "=1.1.0"
emberjson = { git = "https://github.com/bgreni/EmberJson.git", tag = "0.4.0" }

[feature.test.dependencies]
pytest = "*"
"local-helper" = { path = "./helper" }

[feature.test.pypi-dependencies]
requests = ">=2.31"

[target.linux-64.dependencies]
libcurl = ">=8"

[dependencies.lightbug_http]
git = "https://github.com/Lightbug-HQ/lightbug_http"
branch = "main"
"""


def test_pixi_toml() raises:
    var rows = manifest_deps("pixi.toml", PIXI_BUILD)
    var p = _find(rows, PROVIDES, "floki")
    assert_true(p >= 0)
    assert_equal(rows[p].kind, "package")
    # A build backend's or a Mojo package's `name` isn't a dependency or a
    # published name.
    assert_equal(_find(rows, PROVIDES, "floki_pkg"), -1)
    assert_equal(_find(rows, DEPENDS, "pixi-build-mojo"), -1)
    var e = _find(rows, DEPENDS, "emberjson", "dependencies")
    assert_true(e >= 0)
    assert_equal(rows[e].kind, "git")
    assert_equal(rows[e].dep_repo, "bgreni/EmberJson")
    assert_equal(rows[_find(rows, DEPENDS, "curl_wrapper")].dep_repo, "thatstoasty/mojo-curl")
    var st = _find(rows, DEPENDS, "small_time")
    assert_equal(rows[st].kind, "conda")
    assert_equal(rows[st].dep_repo, "")
    assert_equal(_find(rows, DEPENDS, "mojo_datetime"), -1)
    assert_true(_find(rows, DEPENDS, "emberjson", "package.run-dependencies") >= 0)
    assert_equal(rows[_find(rows, DEPENDS, "local-helper")].kind, "path")
    var rq = _find(rows, DEPENDS, "requests")
    assert_equal(rows[rq].kind, "pypi")
    assert_equal(rows[rq].section, "feature.test.pypi-dependencies")
    assert_true(_find(rows, DEPENDS, "libcurl", "target.linux-64.dependencies") >= 0)
    var lb = _find(rows, DEPENDS, "lightbug_http")
    assert_equal(rows[lb].kind, "git")
    assert_equal(rows[lb].dep_repo, "Lightbug-HQ/lightbug_http")
    assert_equal(rows[lb].section, "dependencies")
    # No task or channel line is taken for a dependency.
    assert_equal(_find(rows, DEPENDS, "tests"), -1)
    assert_equal(_find(rows, DEPENDS, "channels"), -1)
    # Toolchain left out, names counted once across tables.
    assert_equal(
        declared_count(rows), 9
    )  # emberjson mojo-curl curl_wrapper small_time pytest local-helper requests libcurl lightbug_http


comptime MOJOPROJECT = """[project]
authors = ["Someone <someone@example.com>"]
channels = ["conda-forge", "https://conda.modular.com/max", "https://repo.prefix.dev/modular-community"]
description = "Add a short description here"
name = "mojo-learn"
platforms = ["osx-arm64", "linux-64"]
version = "0.1.0"

[tasks]
test = "magic run mojo test"

[dependencies]
max = ">=24.5.0,<25"
numojo = ">=0.4,<0.5"
python = ">=3.11,<3.13"
"""


def test_mojoproject_toml() raises:
    var rows = manifest_deps("mojoproject.toml", MOJOPROJECT)
    var w = _find(rows, PROVIDES, "mojo-learn")
    assert_equal(rows[w].kind, "workspace")
    assert_true(_find(rows, DEPENDS, "numojo") >= 0)
    assert_true(_find(rows, DEPENDS, "max") >= 0)
    assert_equal(declared_count(rows), 2)  # numojo, python


comptime PYPROJECT = """[build-system]
requires = ["hatchling"]

[project]
name = "mojo-tools"
version = "0.2.0"
dependencies = [
    "numpy>=1.26",
    "max==25.1.0",
    "decimojo @ git+https://github.com/forfudan/decimojo.git@v0.3",
]

[project.optional-dependencies]
test = ["pytest>=8", "hypothesis"]

[tool.pixi.workspace]
channels = ["conda-forge", "https://conda.modular.com/max"]
platforms = ["linux-64"]

[tool.pixi.dependencies]
mojo = "==0.25.6"
emberjson = ">=0.2"
"""


def test_pyproject_toml() raises:
    var rows = manifest_deps("pyproject.toml", PYPROJECT)
    assert_equal(rows[_find(rows, PROVIDES, "mojo-tools")].kind, "pyproject")
    assert_equal(_find(rows, DEPENDS, "hatchling"), -1)
    var n = _find(rows, DEPENDS, "numpy")
    assert_equal(rows[n].kind, "pypi")
    assert_equal(rows[n].section, "project.dependencies")
    var d = _find(rows, DEPENDS, "decimojo")
    assert_equal(rows[d].kind, "git")
    assert_equal(rows[d].dep_repo, "forfudan/decimojo")
    assert_equal(rows[_find(rows, DEPENDS, "hypothesis")].section, "project.optional-dependencies.test")
    var e = _find(rows, DEPENDS, "emberjson")
    assert_equal(rows[e].kind, "conda")
    assert_equal(rows[e].section, "dependencies")


comptime RECIPE = """# yaml-language-server: $schema=https://raw.githubusercontent.com/prefix-dev/recipe-format/main/schema.json

context:
  version: "0.26.2.0"
  name: lightbug_http

package:
  name: ${{ name }}
  version: ${{ version }}

source:
  - path: ../lightbug_http
  - git: https://github.com/Lightbug-HQ/lightbug_http.git

build:
  number: 0
  script:
    - mkdir -p ${PREFIX}/lib/mojo
    - pixi run mojo package . -o ${PREFIX}/lib/mojo/lightbug_http.mojopkg

requirements:
  build:
    - ${{ compiler('c') }}
  host:
    - mojo-compiler =0.26.2
  run:
    - max >=0.26.2.0,<0.26.3
    - small_time >=26.2.0,<26.3
    - "emberjson >=0.3.1,<0.4"
    - if: unix
      then: libcurl
    - ${{ pin_compatible('mojo-compiler') }}
  run_constraints:
    - openssl >=3

tests:
  - script:
      - if: unix
        then:
          - python run_tests.py
    requirements:
      run:
        - pytest

about:
  homepage: https://github.com/saviorand/lightbug_http
  license: MIT
  summary: Lightbug is a simple and sweet HTTP framework for Mojo
"""


def test_recipe_yaml() raises:
    assert_true(is_recipe("recipe.yaml"))
    assert_true(is_recipe("recipes/recipe.yaml"))
    assert_true(not is_recipe("recipes/emberjson/recipe.yaml"))
    var rows = manifest_deps("recipes/recipe.yaml", RECIPE)
    var p = _find(rows, PROVIDES, "lightbug_http")
    assert_equal(rows[p].kind, "recipe")
    assert_equal(rows[_find(rows, DEPENDS, "small_time")].section, "requirements.run")
    assert_true(_find(rows, DEPENDS, "emberjson") >= 0)
    assert_true(_find(rows, DEPENDS, "mojo-compiler", "requirements.host") >= 0)
    assert_true(_find(rows, DEPENDS, "libcurl") >= 0)
    assert_true(_find(rows, DEPENDS, "pytest") >= 0)
    # Constraints, scripts, sources and Jinja aren't requirements.
    assert_equal(_find(rows, DEPENDS, "openssl"), -1)
    assert_equal(_find(rows, DEPENDS, "python"), -1)
    assert_equal(_find(rows, DEPENDS, "mkdir"), -1)
    assert_equal(declared_count(rows), 4)  # small_time emberjson libcurl pytest


def test_requirements_txt() raises:
    var rows = manifest_deps(
        "requirements.txt",
        "# pinned\n-r base.txt\nnumpy==1.26.4\nmax>=25.1 ; python_version>='3.10'\n"
        "-e git+https://github.com/owner/mojo-helpers.git#egg=mojo_helpers\n"
        "--extra-index-url https://example.com\n",
    )
    assert_true(_find(rows, DEPENDS, "numpy") >= 0)
    var h = _find(rows, DEPENDS, "mojo_helpers")
    assert_equal(rows[h].dep_repo, "owner/mojo-helpers")
    assert_equal(rows[h].kind, "git")
    assert_equal(declared_count(rows), 2)


def test_github_repo() raises:
    assert_equal(github_repo("https://github.com/bgreni/EmberJson.git"), "bgreni/EmberJson")
    assert_equal(github_repo("git+https://github.com/o/r.git@v1"), "o/r")
    assert_equal(github_repo("git@github.com:o/duckdb.mojo.git"), "o/duckdb.mojo")
    assert_equal(github_repo("https://github.com/o/r/archive/refs/tags/v1.tar.gz"), "o/r")
    assert_equal(github_repo("https://gitlab.com/o/r"), "")
    assert_equal(github_repo("https://github.com/o"), "")
    assert_equal(norm_name("Lightbug_HTTP"), "lightbug-http")


def test_encode_round_trip() raises:
    var rows = dedupe(manifest_deps("pixi.toml", PIXI_BUILD))
    var back = decode_deps(encode_deps(rows))
    assert_equal(len(back), len(rows))
    for i in range(len(rows)):
        assert_equal(back[i].name, rows[i].name)
        assert_equal(back[i].dep_repo, rows[i].dep_repo)
        assert_equal(back[i].section, rows[i].section)
    assert_equal(len(dedupe(manifest_deps("pixi.toml", String(PIXI_BUILD, "\n[dependencies]\nsmall_time = \"*\"\n")))), len(rows))


def _rows(repo: String, path: String, text: String) -> List[RepoDep]:
    var out = List[RepoDep]()
    for ref d in manifest_deps(path, text):
        out.append(RepoDep(repo, 0, d.copy()))
    return out^


def test_resolve() raises:
    var repos: List[String] = [
        "thatstoasty/floki", "bgreni/EmberJson", "Lightbug-HQ/lightbug_http",
        "thatstoasty/small-time", "Mojo-Numerics-and-Algorithms-group/NuMojo",
        "someone/mojo-learn", "modular/modular", "a/utils", "b/utils",
    ]
    var rows = _rows("thatstoasty/floki", "pixi.toml", PIXI_BUILD)
    rows.extend(_rows("Lightbug-HQ/lightbug_http", "recipes/recipe.yaml", RECIPE))
    rows.extend(_rows("someone/mojo-learn", "mojoproject.toml", MOJOPROJECT))
    # NuMojo publishes `numojo` ([package] name), not its repo's name.
    rows.append(RepoDep("Mojo-Numerics-and-Algorithms-group/NuMojo", 0, Dep(PROVIDES, "package", "numojo", "", "package", "pixi.toml")))
    # A workspace named after a template doesn't claim the name.
    rows.append(RepoDep("a/utils", 0, Dep(PROVIDES, "workspace", "python", "", "workspace", "pixi.toml")))
    rows.append(RepoDep("someone/mojo-learn", 0, Dep(DEPENDS, "conda", "utils", "", "dependencies", "pixi.toml")))
    var g = resolve(repos, rows)
    ref floki = g.depends_on["thatstoasty/floki"]
    # emberjson by URL (the case differs from the census name), lightbug by
    # its subtable's URL, small_time by the repo name; mojo-curl isn't in the
    # census; the toolchain isn't a library.
    assert_equal(len(floki), 3)
    assert_equal(floki[0], "bgreni/EmberJson")
    assert_equal(floki[1], "Lightbug-HQ/lightbug_http")
    assert_equal(floki[2], "thatstoasty/small-time")
    ref lb = g.depends_on["Lightbug-HQ/lightbug_http"]
    assert_equal(len(lb), 2)  # emberjson by name, small_time by name
    ref learn = g.depends_on["someone/mojo-learn"]
    # numojo by the name NuMojo publishes; `utils` is two repos' name, and
    # `python` a workspace name: neither resolves.
    assert_equal(len(learn), 1)
    assert_equal(learn[0], "Mojo-Numerics-and-Algorithms-group/NuMojo")
    ref eb = g.used_by["bgreni/EmberJson"]
    assert_equal(len(eb), 2)
    assert_equal(eb[0], "Lightbug-HQ/lightbug_http")
    assert_equal(eb[1], "thatstoasty/floki")
    assert_true("modular/modular" not in g.used_by)
    assert_true("thatstoasty/floki" not in g.used_by)
    assert_equal(len(g.declared["thatstoasty/floki"]), 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
