#!/usr/bin/env python3
"""Renovate postUpgradeTask: update the `version` field after a pin bump.

Each entry in docker/*/extensions.<major>.json has two versions:

  package_version  the apt pin that Renovate bumps
  version          the SQL extension version that `make test` compares with
                   default_version from pg_available_extensions

The second cannot be derived from the first. After a bump, this script reads
default_version from the .control file in the pinned .deb and writes it to
`version`. It looks in the pinned package and in its `-scripts` sibling,
because postgis-3 and pgrouting ship the file there. Entries with no .control
file, such as auto_explain and wal2json, keep their `version`.

The script handles the entries whose package_version differs from --base-ref
(default HEAD). Renovate runs it before it commits, so HEAD is the unbumped
state. With --all it checks every pinned entry. Add --dry-run to avoid writing.

It also checks that each changed pin is in the PGDG index for amd64 and arm64.
Percona packages (pg_stat_monitor) are checked in the Percona index for the
same PG major.
CI builds both, and Renovate looks at amd64 only. The same check covers the
pgBackRest and PostGIS CLI pins in docker/*/Dockerfile, which have no `version`
field. The pgBackRest suffix uses ${VERSION_ID}, so that pin is checked on
bookworm and trixie. The PostGIS CLI is PG 17 only, so it is checked on
bookworm.

The script uses only the standard library, plus `zstd` for .deb files that use
it. It edits the files in place, so the formatting does not change.

It exits non-zero when a pin cannot be verified. Renovate then reports an
artifact error on the PR.
"""

import argparse
import glob
import gzip
import io
import json
import lzma
import bz2
import re
import subprocess
import sys
import tarfile
import urllib.request

PGDG = "https://apt.postgresql.org/pub/repos/apt"
# Percona publishes one repository per PG major, with a suite per Debian
# release. The pin ends with the suite name, such as 1:2.4.0-1.bookworm.
PERCONA = "https://repo.percona.com/ppg-{major}/apt"
ARCHES = ("amd64", "arm64")
# PGDG appends the Debian major to the package version: pgdg12 on bookworm,
# pgdg13 on trixie. Reading the suite from the pin avoids duplicating the
# PG-major to suite mapping that lives in the Makefile.
SUITES = {"pgdg12": "bookworm-pgdg", "pgdg13": "trixie-pgdg"}

_indexes = {}


def repo_for(pkg, pin):
    """Return (repository URL, suite) that serves a pin, or None."""
    m = re.fullmatch(r"percona-.*?(\d+)", pkg)
    if m:
        s = re.search(r"\.(bookworm|trixie)$", pin)
        return (PERCONA.format(major=m.group(1)), s.group(1)) if s else None
    m = re.search(r"(pgdg\d+)\+", pin)
    suite = SUITES.get(m.group(1)) if m else None
    return (PGDG, suite) if suite else None


def fetch(url):
    last = None
    for _ in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "xataio-postgres-images-renovate"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                return resp.read()
        except OSError as err:
            last = err
    raise RuntimeError(f"cannot fetch {url}: {last}")


def package_index(repo, suite, arch):
    """Map (package, version) to the Filename in a repository's index."""
    key = (repo, suite, arch)
    if key not in _indexes:
        raw = gzip.decompress(fetch(f"{repo}/dists/{suite}/main/binary-{arch}/Packages.gz"))
        index = {}
        for stanza in raw.decode("utf-8", "replace").split("\n\n"):
            fields = dict(re.findall(r"^(Package|Version|Filename): (.*)$", stanza, re.M))
            if len(fields) == 3:
                index[(fields["Package"], fields["Version"])] = fields["Filename"]
        _indexes[key] = index
    return _indexes[key]


def decompress(name, data):
    if name.endswith(".xz"):
        return lzma.decompress(data)
    if name.endswith(".gz"):
        return gzip.decompress(data)
    if name.endswith(".bz2"):
        return bz2.decompress(data)
    if name.endswith(".zst"):
        return subprocess.run(["zstd", "-dc"], input=data, capture_output=True, check=True).stdout
    return data


def deb_control_versions(deb):
    """Return {extension name: default_version} for the .control files in a .deb."""
    if not deb.startswith(b"!<arch>\n"):
        raise ValueError("not an ar archive")
    pos = 8
    while pos + 60 <= len(deb):
        header = deb[pos : pos + 60]
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        body = deb[pos + 60 : pos + 60 + size]
        pos += 60 + size + (size % 2)
        if name.startswith("data.tar"):
            break
    else:
        raise ValueError("no data.tar member")
    versions = {}
    with tarfile.open(fileobj=io.BytesIO(decompress(name, body))) as tar:
        for member in tar:
            m = re.search(r"/extension/([^/]+)\.control$", member.name)
            if not m or not member.isfile():
                continue
            text = tar.extractfile(member).read().decode("utf-8", "replace")
            d = re.search(r"^\s*default_version\s*=\s*'([^']*)'", text, re.M)
            if d:
                versions[m.group(1)] = d.group(1)
    return versions


def entry_spans(text):
    """Yield (start, end) of each object directly inside a top-level array."""
    depth = 0
    in_str = esc = False
    start = None
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "{[":
            depth += 1
            if ch == "{" and depth == 3:
                start = i
        elif ch in "}]":
            if ch == "}" and depth == 3:
                yield start, i + 1
            depth -= 1


# Pins in the Dockerfiles: (regex for the value, package, suites to check).
# The suffix variables stand for the suffixes that the Makefile and the base
# image set.
DOCKERFILE_PINS = [
    (re.compile(r'"pgbackrest=([^"]+)"'), "pgbackrest",
     {"${VERSION_ID}": {"bookworm-pgdg": "12", "trixie-pgdg": "13"}}),
    (re.compile(r"POSTGIS_PKG_VERSION=(\S+)"), "postgis",
     {"${PGDG_SUFFIX}": {"bookworm-pgdg": "pgdg12+1"}}),
]


def dockerfile_pins(text):
    """Yield (package, suite, full version) for each pin in a Dockerfile."""
    for regex, pkg, variables in DOCKERFILE_PINS:
        for m in regex.finditer(text):
            value = m.group(1)
            if not any(v in value for v in variables):
                suite = SUITES.get(re.search(r"(pgdg\d+)\+", value).group(1))
                yield pkg, suite, value
                continue
            for var, per_suite in variables.items():
                for suite, replacement in per_suite.items():
                    yield pkg, suite, value.replace(var, replacement)


def check_dockerfiles(paths, ref, check_all):
    failures = 0
    for path in paths:
        with open(path, encoding="utf-8") as f:
            now = set(dockerfile_pins(f.read()))
        base = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
        before = set() if check_all or base.returncode != 0 else set(dockerfile_pins(base.stdout))
        for pkg, suite, pin in sorted(now - before):
            missing = [a for a in ARCHES if (pkg, pin) not in package_index(PGDG, suite, a)]
            if missing:
                print(f"FAIL {path}: {pkg}={pin} is not in {suite} for {', '.join(missing)}")
                failures += 1
            else:
                print(f"ok   {path}: {pkg}={pin} is in {suite}")
    return failures


def base_manifest(path, ref):
    out = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 else None


def changed_entries(path, manifest, ref, check_all):
    base = {} if check_all else {e["name"]: e for e in (base_manifest(path, ref) or {}).get("extensions", [])}
    for entry in manifest.get("extensions", []):
        pin = entry.get("package_version")
        if not entry.get("package") or not pin:
            continue
        old = base.get(entry["name"], {})
        if check_all or old.get("package_version") != pin:
            yield entry


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--base-ref", default="HEAD")
    ap.add_argument("--all", action="store_true", help="check every pinned entry, not only changed ones")
    ap.add_argument("--dry-run", action="store_true", help="report changes without writing files")
    ap.add_argument("files", nargs="*", help="manifests to process (default: docker/*/extensions.*.json)")
    args = ap.parse_args()

    failures = 0
    debs = {}
    for path in args.files or sorted(glob.glob("docker/*/extensions.*.json")):
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
        manifest = json.loads(text)
        edits = []  # (new text of the entry span, start, end)
        spans = {}
        for s, e in entry_spans(text):
            spans[json.loads(text[s:e]).get("name")] = (s, e)

        for entry in changed_entries(path, manifest, args.base_ref, args.all):
            pkg, pin, name = entry["package"], entry["package_version"], entry["name"]
            repo, suite = repo_for(pkg, pin) or (None, None)
            if not suite:
                print(f"FAIL {path}: {name}: cannot tell the suite from {pin}")
                failures += 1
                continue
            missing = [a for a in ARCHES if (pkg, pin) not in package_index(repo, suite, a)]
            if missing:
                print(f"FAIL {path}: {pkg}={pin} is not in {suite} for {', '.join(missing)}")
                failures += 1
                continue
            # The control file sometimes ships in a sibling -scripts package
            # (postgis-3, pgrouting) at the same version.
            controls = {}
            for candidate in (pkg, pkg + "-scripts"):
                filename = package_index(repo, suite, "amd64").get((candidate, pin))
                if filename is None:
                    continue
                if filename not in debs:
                    debs[filename] = deb_control_versions(fetch(f"{repo}/{filename}"))
                controls.update(debs[filename])
            # postgis ships postgis-3.control, which `CREATE EXTENSION postgis`
            # resolves through a symlink.
            new = controls.get(name)
            if new is None:
                new = next((v for k, v in controls.items() if re.fullmatch(re.escape(name) + r"-\d+", k)), None)
            if new is None:
                print(f"keep {path}: {name} has no .control in {pkg}={pin}; version stays {entry['version']}")
                continue
            if new == entry["version"]:
                print(f"ok   {path}: {name} {new}")
                continue
            s, e = spans[name]
            span = text[s:e]
            pattern = re.compile(r'(?<!\\)("version"\s*:\s*")' + re.escape(entry["version"]) + '"')
            if len(pattern.findall(span)) != 1:
                print(f"FAIL {path}: {name}: cannot locate the version field to edit")
                failures += 1
                continue
            edits.append((s, e, pattern.sub(lambda mm: mm.group(1) + new + '"', span)))
            print(f"set  {path}: {name} version {entry['version']} -> {new} ({pkg}={pin})")

        if edits and not args.dry_run:
            for s, e, replacement in sorted(edits, reverse=True):
                text = text[:s] + replacement + text[e:]
            json.loads(text)  # must still parse
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(text)

    if not args.files:
        failures += check_dockerfiles(sorted(glob.glob("docker/*/Dockerfile")), args.base_ref, args.all)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
