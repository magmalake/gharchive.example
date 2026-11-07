"""The dependencies a repository declares at its HEAD, and the names it
publishes itself under, from its manifests: `pixi.toml`, `mojoproject.toml`,
`pyproject.toml`, `requirements.txt` and a rattler-build `recipe.yaml`.

`manifest_deps` reads one file into `Dep` rows (`mojo_versions` stores them
in `mojo.repo_deps`); `resolve` turns every repository's rows into the
Mojo libraries each depends on and the repositories that depend on each,
which the console computes when it builds its pages, so the reverse counts
need no pipeline of their own.

The readers are line-based, like the version readers in `versions.mojo`: a
manifest is TOML or YAML a person wrote by a template, and the few shapes
that matter (a `name = "spec"` line under a dependencies table, a `- name
spec` item under `requirements:`) don't need a full parser.
"""

from versions import packages

comptime DEPENDS = "depends"
"""`relation` of a declared dependency."""
comptime PROVIDES = "provides"
"""`relation` of a name the repository publishes itself under: its
`[package]` name (pixi-build), a recipe's `package.name`, a pyproject's
`[project]` name, or a pixi workspace's name (kind `workspace`)."""


@fieldwise_init
struct Dep(Copyable, Movable):
    """One row of `mojo.repo_deps` (less `repo` and `read_at`, which the
    pipeline knows)."""

    var relation: String
    """`depends` or `provides`."""
    var kind: String
    """For `depends`: `conda` (a pixi/magic or recipe package), `pypi`,
    `git`, `url` or `path`. For `provides`: `package`, `recipe`, `pyproject`
    or `workspace`."""
    var name: String
    """The package name as written."""
    var dep_repo: String
    """`owner/name` when the dependency is a GitHub URL (`git = ...`,
    `url = ...`, `name @ git+https://...`), else empty."""
    var section: String
    """Where in the file: `dependencies`, `feature.test.dependencies`,
    `package.run-dependencies`, `requirements.host`, `project.dependencies`."""
    var file: String


def toolchain(name: String) -> Bool:
    """Whether `name` is Modular's toolchain (`mojo`, `max`, ...) rather than
    a library: every Mojo project depends on it, so it isn't counted."""
    var n = norm_name(name)
    for p in packages():
        if n == p:
            return True
    return n == "max-pipelines" or n == "mojo-compiler" or n == "mblack"


def norm_name(name: String) -> String:
    """A package name compared the way conda and PyPI do: lower case, `_`
    and `.` as `-` (`Lightbug_HTTP` and `lightbug-http` are one name)."""
    return String(name.strip()).lower().replace("_", "-").replace(".", "-")


def _name_char(c: UInt8) -> Bool:
    """Whether `c` can be in a package name."""
    return (
        (c >= 48 and c <= 57) or (c >= 97 and c <= 122) or (c >= 65 and c <= 90)
        or c == UInt8(ord("-")) or c == UInt8(ord("_")) or c == UInt8(ord("."))
    )


def _leading_name(s: String) -> String:
    """The package name at the start of `s` (`numpy>=1.2` gives `numpy`)."""
    var b = s.as_bytes()
    var i = 0
    while i < len(b) and _name_char(b[i]):
        i += 1
    return String(s[byte=:i])


def github_repo(url: String) -> String:
    """`owner/name` of a GitHub URL (`https://github.com/o/r.git`,
    `git+https://github.com/o/r@v1`, `git@github.com:o/r.git`,
    `https://github.com/o/r/archive/v1.tar.gz`), or empty."""
    var at = url.find("github.com")
    if at < 0:
        return String()
    var i = at + 10
    var b = url.as_bytes()
    if i >= len(b) or (b[i] != UInt8(ord("/")) and b[i] != UInt8(ord(":"))):
        return String()
    i += 1
    var parts = List[String]()
    var start = i
    while i <= len(b) and len(parts) < 2:
        if i == len(b) or not _name_char(b[i]):
            parts.append(String(url[byte=start:i]))
            if i == len(b) or b[i] != UInt8(ord("/")):
                break
            start = i + 1
        i += 1
    if len(parts) < 2 or parts[0].byte_length() == 0 or parts[1].byte_length() == 0:
        return String()
    var name = parts[1]
    if name.endswith(".git"):
        var cut = String(name[byte = : name.byte_length() - 4])
        name = cut^
    if name.byte_length() == 0:
        return String()
    return String(parts[0], "/", name)


def _strip_comment(line: String, after_space: Bool = False) -> String:
    """`line` without a `#` comment (one outside quotes). With `after_space`,
    as pip reads it: a `#` starts a comment only at the start of the line or
    after a space (`...git#egg=name` is part of a URL)."""
    var b = line.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("#")) and (
            not after_space or i == 0 or b[i - 1] == UInt8(32) or b[i - 1] == UInt8(9)
        ):
            return String(line[byte=:i])
    return line


def _unquote(s: String) -> String:
    """`s` stripped, without surrounding quotes."""
    var t = String(s.strip())
    if t.byte_length() >= 2 and (
        (t.startswith('"') and t.endswith('"')) or (t.startswith("'") and t.endswith("'"))
    ):
        return String(t[byte = 1 : t.byte_length() - 1])
    return t^


def _depth(s: String) -> Int:
    """How many `[`/`{` `s` opens and doesn't close, outside quotes."""
    var b = s.as_bytes()
    var quote = UInt8(0)
    var d = 0
    for c in b:
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("[")) or c == UInt8(ord("{")):
            d += 1
        elif c == UInt8(ord("]")) or c == UInt8(ord("}")):
            d -= 1
    return d


def _split_key(line: String) -> Tuple[String, String]:
    """A TOML `key = value` line as (key, value), the key unquoted; ("", "")
    when the line isn't one."""
    var b = line.as_bytes()
    var quote = UInt8(0)
    for i in range(len(b)):
        var c = b[i]
        if quote != 0:
            if c == quote:
                quote = 0
        elif c == UInt8(ord('"')) or c == UInt8(ord("'")):
            quote = c
        elif c == UInt8(ord("=")):
            var key = _unquote(String(line[byte=:i]))
            return (key^, String(String(line[byte = i + 1 :]).strip()))
    return (String(), String())


def _inline_str(value: String, key: String) -> String:
    """The string `key` has in a TOML inline table (`{ git = "..." }`), or
    empty."""
    var at = 0
    while True:
        var i = value.find(key, at)
        if i < 0:
            return String()
        at = i + 1
        var b = value.as_bytes()
        if i > 0 and _name_char(b[i - 1]):
            continue
        var j = i + key.byte_length()
        while j < len(b) and b[j] == UInt8(32):
            j += 1
        if j >= len(b) or b[j] != UInt8(ord("=")):
            continue
        j += 1
        while j < len(b) and b[j] == UInt8(32):
            j += 1
        if j >= len(b) or (b[j] != UInt8(ord('"')) and b[j] != UInt8(ord("'"))):
            continue
        var q = b[j]
        var k = j + 1
        while k < len(b) and b[k] != q:
            k += 1
        return String(value[byte = j + 1 : k])


def _section_name(header: String) -> String:
    """`[feature."test".dependencies]` as `feature.test.dependencies`."""
    var s = String(header.strip())
    while s.startswith("["):
        var t = String(s[byte=1:])
        s = t^
    while s.endswith("]"):
        var t = String(s[byte = : s.byte_length() - 1])
        s = t^
    var parts = s.split(".")
    var out = String()
    for i in range(len(parts)):
        if i > 0:
            out += "."
        out += _unquote(String(parts[i]))
    return out^


def _dep_table(section: String) -> Bool:
    """Whether a pixi table lists dependencies: its last part is
    `dependencies`, `host-dependencies`, `pypi-dependencies`, ..."""
    var parts = section.split(".")
    var last = String(parts[len(parts) - 1])
    return last == "dependencies" or last.endswith("-dependencies")


def _strip_prefix(section: String, prefix: String) -> String:
    if section.startswith(prefix):
        return String(section[byte = prefix.byte_length() :])
    return section


def _toml_dep(name: String, value: String, section: String, file: String) -> Dep:
    """A dependency line of a pixi table: `name = "spec"` or `name = { git =
    "...", rev = "..." }`."""
    var pypi = "pypi" in section
    var kind = String("pypi") if pypi else String("conda")
    var repo = String()
    if value.startswith("{"):
        var git = _inline_str(value, "git")
        var url = _inline_str(value, "url")
        var path = _inline_str(value, "path")
        if git.byte_length() > 0:
            kind = String("git")
            repo = github_repo(git)
        elif url.byte_length() > 0:
            kind = String("url")
            repo = github_repo(url)
        elif path.byte_length() > 0:
            kind = String("path")
    return Dep(String(DEPENDS), kind^, name, repo^, section, file)


def _pep508(req: String, section: String, file: String) -> Optional[Dep]:
    """A PEP 508 requirement (`numpy>=1.26`, `foo @ git+https://github.com/o/r`)
    as a `pypi` (or `git`/`url`) dependency; none if it names no package."""
    var r = String(req.strip())
    var name = _leading_name(r)
    if name.byte_length() == 0:
        return None
    var kind = String("pypi")
    var repo = String()
    var at = r.find("@")
    if at > 0:
        var url = String(String(r[byte = at + 1 :]).strip())
        repo = github_repo(url)
        kind = String("git") if url.startswith("git+") else String("url")
    return Dep(String(DEPENDS), kind^, name^, repo^, section, file)


def _array_strings(text: String) -> List[String]:
    """The quoted strings of a TOML array's text."""
    var out = List[String]()
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == UInt8(ord('"')) or c == UInt8(ord("'")):
            var k = i + 1
            while k < len(b) and b[k] != c:
                k += 1
            out.append(String(text[byte = i + 1 : k]))
            i = k + 1
        else:
            i += 1
    return out^


def toml_deps(text: String, file: String) -> List[Dep]:
    """The dependencies and published names of a `pixi.toml`,
    `mojoproject.toml` or `pyproject.toml` (whose pixi tables are under
    `tool.pixi`, and whose PEP 621 lists are `project.dependencies`,
    `project.optional-dependencies` and `dependency-groups`)."""
    var out = List[Dep]()
    var pyproject = file.endswith("pyproject.toml")
    var section = String()
    # A multi-line value (`dependencies = [` then a line per item, or an
    # inline table broken over lines) is gathered until its brackets close.
    var pending_key = String()
    var pending = String()
    var depth = 0
    var sub = -1
    for raw in text.split("\n"):
        var line = String(_strip_comment(String(raw)).strip())
        if depth > 0:
            pending += " "
            pending += line
            depth += _depth(line)
            if depth <= 0:
                _toml_entry(out, sub, section, pending_key, pending, file, pyproject)
                depth = 0
            continue
        if line.byte_length() == 0:
            continue
        if line.startswith("["):
            section = _section_name(line)
            if pyproject:
                section = _strip_prefix(section, "tool.pixi.")
            # `[dependencies.foo]`: the table is one dependency, `foo`; its
            # `git`/`url`/`path` keys, if any, follow (`_toml_entry`).
            sub = -1
            var parts = section.split(".")
            if len(parts) >= 2:
                var last = String(parts[len(parts) - 1])
                var parent = String(section[byte = : section.byte_length() - last.byte_length() - 1])
                if _dep_table(parent):
                    sub = len(out)
                    out.append(_toml_dep(last, String(), parent, file))
            continue
        var kv = _split_key(line)
        if kv[0].byte_length() == 0:
            continue
        var d = _depth(kv[1])
        if d > 0:
            pending_key = kv[0]
            pending = kv[1]
            depth = d
            continue
        _toml_entry(out, sub, section, kv[0], kv[1], file, pyproject)
    return out^


def _toml_entry(
    mut out: List[Dep], sub: Int, section: String, key: String, value: String,
    file: String, pyproject: Bool,
):
    """One `key = value` of table `section`, into `out` if it is a
    dependency or a published name. `sub` is the row of a
    `[dependencies.foo]` table being read, or -1."""
    if section == "package" and key == "name":
        out.append(Dep(String(PROVIDES), String("package"), _unquote(value), String(), section, file))
        return
    if (section == "workspace" or section == "project") and key == "name":
        var kind = String("pyproject") if pyproject and section == "project" else String("workspace")
        out.append(Dep(String(PROVIDES), kind^, _unquote(value), String(), section, file))
        return
    if pyproject and (
        (section == "project" and key == "dependencies")
        or section == "project.optional-dependencies"
        or section == "dependency-groups"
    ):
        var where = String(section, ".", key) if section != "project" else String("project.dependencies")
        for s in _array_strings(value):
            var d = _pep508(s, where, file)
            if d:
                out.append(d.value().copy())
        return
    if pyproject and section == "project":
        return
    if sub >= 0:
        # `[dependencies.foo]` with `git = "..."` under it.
        if key == "git" or key == "url" or key == "path":
            var d = _toml_dep(out[sub].name, String("{ ", key, " = ", value, " }"), out[sub].section, file)
            out[sub] = d^
        return
    if _dep_table(section):
        out.append(_toml_dep(key, value, section, file))


def _indent(line: String) -> Int:
    var b = line.as_bytes()
    var i = 0
    while i < len(b) and (b[i] == UInt8(32) or b[i] == UInt8(9)):
        i += 1
    return i


def _yaml_value(line: String) -> String:
    """The value of a `key: value` YAML line, unquoted; empty for none."""
    var colon = line.find(":")
    if colon < 0:
        return String()
    return _unquote(String(line[byte = colon + 1 :]))


def _subst(value: String, context: Dict[String, String]) -> String:
    """`${{ name }}` (and `${{ name | lower }}`) replaced from the recipe's
    `context:`; empty if it is some other template."""
    var v = String(value.strip())
    if not v.startswith("${{"):
        return v^
    var inner = String(String(v[byte=3:]).strip())
    if inner.endswith("}}"):
        var cut = String(String(inner[byte = : inner.byte_length() - 2]).strip())
        inner = cut^
    var bar = inner.find("|")
    var lower = False
    if bar >= 0:
        lower = "lower" in String(inner[byte = bar + 1 :])
        var cut = String(String(inner[byte=:bar]).strip())
        inner = cut^
    if inner in context:
        var out = context.get(inner, String())
        return out.lower() if lower else out
    return String()


def recipe_deps(text: String, file: String) -> List[Dep]:
    """The requirements and package names of a rattler-build `recipe.yaml`:
    `package: name:` (also in each of `outputs:`), and the `- name spec`
    items under `requirements:` `build:`, `host:` and `run:` (the tests'
    requirements too). Jinja items (`${{ compiler('c') }}`, `pin_compatible`)
    and `if:` selectors are skipped; a selector's `then:` item is read."""
    var out = List[Dep]()
    var context = Dict[String, String]()
    var in_context = -1
    var in_package = -1
    var in_reqs = -1
    var req_key = String()
    for raw in text.split("\n"):
        var full = _strip_comment(String(raw))
        var line = String(full.strip())
        if line.byte_length() == 0:
            continue
        var ind = _indent(full)
        if in_context >= 0 and ind <= in_context:
            in_context = -1
        if in_package >= 0 and ind <= in_package:
            in_package = -1
        if in_reqs >= 0 and ind <= in_reqs:
            in_reqs = -1
            req_key = String()
        if line == "context:":
            in_context = ind
            continue
        if line == "package:" or line == "- package:":
            in_package = ind
            continue
        if line == "requirements:":
            in_reqs = ind
            req_key = String()
            continue
        if in_context >= 0 and ":" in line:
            var k = String(line[byte = : line.find(":")])
            context[String(k.strip())] = _yaml_value(line)
            continue
        if in_package >= 0 and line.startswith("name:"):
            var n = _subst(_yaml_value(line), context)
            if n.byte_length() > 0:
                out.append(Dep(String(PROVIDES), String("recipe"), n^, String(), String("package"), file))
            continue
        if in_reqs < 0:
            continue
        if not line.startswith("-") and line.endswith(":"):
            # `build:`, `host:`, `run:` (or `run_constraints:`, not read).
            req_key = String(line[byte = : line.byte_length() - 1])
            continue
        if req_key != "build" and req_key != "host" and req_key != "run":
            continue
        var item = String()
        if line.startswith("- "):
            item = String(String(line[byte=2:]).strip())
        elif line.startswith("then:") or line.startswith("else:"):
            item = _yaml_value(line)
        if item.byte_length() == 0 or item.startswith("${{") or item.startswith("if:"):
            continue
        if item.startswith("then:") or item.startswith("else:"):
            item = _yaml_value(item)
        item = _unquote(item)
        var name = _leading_name(item)
        if name.byte_length() == 0:
            continue
        out.append(Dep(String(DEPENDS), String("conda"), name^, String(), String("requirements.", req_key), file))
    return out^


def requirements_deps(text: String, file: String) -> List[Dep]:
    """A pip `requirements.txt`: a PEP 508 line each, `-e git+https://...
    #egg=name` and bare URLs too; `-r` includes and options are skipped."""
    var out = List[Dep]()
    for raw in text.split("\n"):
        var line = String(_strip_comment(String(raw), True).strip())
        if line.byte_length() == 0:
            continue
        if line.startswith("-e ") or line.startswith("git+") or line.startswith("https://"):
            var url = String(String(line[byte = 3 :]).strip()) if line.startswith("-e ") else line
            var egg = url.find("#egg=")
            var name = _leading_name(String(url[byte = egg + 5 :])) if egg >= 0 else String()
            var repo = github_repo(url)
            if name.byte_length() == 0:
                if repo.byte_length() == 0:
                    continue
                name = String(repo[byte = repo.find("/") + 1 :])
            out.append(Dep(String(DEPENDS), String("git") if "git+" in url else String("url"), name^, repo^, String("requirements"), file))
            continue
        if line.startswith("-"):
            continue
        var d = _pep508(line, String("requirements"), file)
        if d:
            out.append(d.value().copy())
    return out^


def is_recipe(path: String) -> Bool:
    """Whether `path` is a recipe of the repository's own package: a
    `recipe.yaml` at the root or in `recipe/`, `recipes/` or `conda/`."""
    return (
        path == "recipe.yaml" or path == "recipe/recipe.yaml"
        or path == "recipes/recipe.yaml" or path == "conda/recipe.yaml"
    )


def manifest_deps(path: String, text: String) -> List[Dep]:
    """The rows of one file, by its name."""
    if path.endswith(".toml"):
        return toml_deps(text, path)
    if path.endswith(".yaml") or path.endswith(".yml"):
        return recipe_deps(text, path)
    if path.endswith(".txt"):
        return requirements_deps(text, path)
    return List[Dep]()


def _clean(s: String) -> String:
    """`s` without the tabs and newlines `encode_deps` separates with."""
    return s.replace("\t", " ").replace("\n", " ")


def encode_deps(rows: List[Dep]) -> String:
    """`rows` as text, one per line, fields tab-separated: how a dista task
    returns them (its codec sends a struct's `String` fields, not a `List`)."""
    var out = String()
    for ref d in rows:
        out.write(
            _clean(d.relation), "\t", _clean(d.kind), "\t", _clean(d.name), "\t",
            _clean(d.dep_repo), "\t", _clean(d.section), "\t", _clean(d.file), "\n",
        )
    return out^


def decode_deps(text: String) -> List[Dep]:
    """What `encode_deps` wrote."""
    var out = List[Dep]()
    for line in text.split("\n"):
        var f = line.split("\t")
        if len(f) != 6:
            continue
        out.append(Dep(String(f[0]), String(f[1]), String(f[2]), String(f[3]), String(f[4]), String(f[5])))
    return out^


def dedupe(rows: List[Dep]) -> List[Dep]:
    """`rows` without repeats of the same (relation, kind, name, repo,
    section, file), in order."""
    var seen = Dict[String, Bool]()
    var out = List[Dep]()
    for ref d in rows:
        var k = String(d.relation, "\t", d.kind, "\t", d.name, "\t", d.dep_repo, "\t", d.section, "\t", d.file)
        if k in seen:
            continue
        seen[k] = True
        out.append(d.copy())
    return out^


def declared_count(rows: List[Dep]) -> Int:
    """Distinct dependencies by name, the toolchain left out: a name in
    `dependencies` and `package.run-dependencies` counts once."""
    var seen = Dict[String, Bool]()
    for ref d in rows:
        if d.relation != DEPENDS or toolchain(d.name):
            continue
        seen[norm_name(d.name)] = True
    return len(seen)


@fieldwise_init
struct RepoDep(Copyable, Movable):
    """A row of `mojo.repo_deps`: a `Dep` with its repository and when it
    was read."""

    var repo: String
    var read_at: Int64
    var dep: Dep


struct DepGraph(Copyable, Movable):
    """What `resolve` found, by repository (as named in `repos`)."""

    var depends_on: Dict[String, List[String]]
    """The census repositories each one depends on, sorted."""
    var used_by: Dict[String, List[String]]
    """The census repositories that depend on each one, sorted."""
    var declared: Dict[String, List[String]]
    """Every dependency each one declares (toolchain left out), by name as
    first written, sorted."""

    def __init__(out self):
        self.depends_on = Dict[String, List[String]]()
        self.used_by = Dict[String, List[String]]()
        self.declared = Dict[String, List[String]]()


def _short(repo: String) -> String:
    """The name part of `owner/name`."""
    var slash = repo.find("/")
    return String(repo[byte = slash + 1 :]) if slash >= 0 else repo


def _sorted(var xs: List[String]) -> List[String]:
    for i in range(1, len(xs)):
        var j = i
        while j > 0 and xs[j - 1].lower() > xs[j].lower():
            xs.swap_elements(j - 1, j)
            j -= 1
    return xs^


def resolve(repos: List[String], rows: List[RepoDep]) raises -> DepGraph:
    """Each repository's dependencies that are census repositories, and the
    reverse.

    A dependency resolves to a repository of `repos`, in this order:
    1. its GitHub URL (`git = "https://github.com/o/r"`), matched without
       regard to case;
    2. a name a census repository publishes (its `[package]` name, a
       recipe's or a pyproject's name), when one repository does; when
       several do, the one whose own name matches;
    3. a census repository whose name matches (`lightbug_http` for
       `Lightbug-HQ/lightbug_http`), when only one has it.
    Names compare by `norm_name`. The toolchain (`mojo`, `max`, ...) and a
    `path` dependency don't resolve, nor does a repository to itself.
    Workspace names aren't used in (2): a workspace is often named after
    the template it came from (`my-project`, `mojo`), not a package."""
    var g = DepGraph()
    var by_lower = Dict[String, String]()
    var by_short = Dict[String, List[String]]()
    for r in repos:
        by_lower[r.lower()] = r
        var s = norm_name(_short(r))
        if s not in by_short:
            by_short[s] = List[String]()
        by_short[s].append(r)
    # Published names, by `norm_name`.
    var provided = Dict[String, List[String]]()
    for ref rd in rows:
        if rd.dep.relation != PROVIDES or rd.dep.kind == "workspace":
            continue
        if rd.repo.lower() not in by_lower:
            continue
        var n = norm_name(rd.dep.name)
        if n.byte_length() == 0:
            continue
        if n not in provided:
            provided[n] = List[String]()
        var owner = by_lower[rd.repo.lower()]
        var have = False
        for x in provided[n]:
            if x == owner:
                have = True
        if not have:
            provided[n].append(owner)
    var deps = Dict[String, Dict[String, Bool]]()
    var declared = Dict[String, Dict[String, String]]()
    for ref rd in rows:
        ref d = rd.dep
        if d.relation != DEPENDS or toolchain(d.name):
            continue
        var me_low = rd.repo.lower()
        if me_low not in by_lower:
            continue
        var me = by_lower[me_low]
        var n = norm_name(d.name)
        if me not in declared:
            declared[me] = Dict[String, String]()
        if n not in declared[me]:
            declared[me][n] = d.name
        var target = String()
        if d.dep_repo.byte_length() > 0:
            target = by_lower.get(d.dep_repo.lower(), String())
        elif d.kind != "path" and d.kind != "url":
            if n in provided:
                ref ps = provided[n]
                if len(ps) == 1:
                    target = ps[0]
                else:
                    for p in ps:
                        if norm_name(_short(p)) == n:
                            target = p
            if target.byte_length() == 0 and n in by_short and len(by_short[n]) == 1:
                target = by_short[n][0]
        if target.byte_length() == 0 or target == me:
            continue
        if me not in deps:
            deps[me] = Dict[String, Bool]()
        deps[me][target] = True
    for e in deps.items():
        var ts = List[String]()
        for t in e.value.keys():
            ts.append(t)
            if t not in g.used_by:
                g.used_by[t] = List[String]()
            g.used_by[t].append(e.key)
        g.depends_on[e.key] = _sorted(ts^)
    var targets = List[String]()
    for t in g.used_by.keys():
        targets.append(t)
    for t in targets:
        g.used_by[t] = _sorted(g.used_by[t].copy())
    for e in declared.items():
        var ns = List[String]()
        for v in e.value.values():
            ns.append(v)
        g.declared[e.key] = _sorted(ns^)
    return g^
