"""Golden cases for haskell_tool's argparse reproduction, from CPython's own argparse.

Run from the package directory with the CPython that ran ghc_wrapper.py (3.13):
    python3 -I testdata/gen_cases.py > testdata/cases.json
It also writes the argument files the "@" cases read, under testdata/at/.
The parsers below are ghc_wrapper.py's and ghc_pkg_registerer.py's (buck2-haskell 74e7e9239c) with type=Path
left out, since the tool normalises paths after parsing; pathlib and os.path are checked separately.
"""
import argparse, json, os.path, pathlib, random, sys


class Exit(Exception):
    def __init__(self, status):
        self.status = status


class Parser(argparse.ArgumentParser):
    def exit(self, status=0, message=None):
        raise Exit(status)

    def error(self, message):
        raise Exit(2)

    def print_help(self, file=None):
        pass


def wrapper():
    p = Parser(add_help=False, fromfile_prefix_chars="@")
    p.add_argument("--buck2-dep", required=False)
    p.add_argument("--buck2-packagedb-dep", required=False)
    p.add_argument("--buck2-package-db", required=False, nargs="*", default=[])
    p.add_argument("--ghc", required=True, type=str)
    p.add_argument("--ghc-dir", type=str)
    p.add_argument("--ghc-argsfile", required=False, type=str)
    p.add_argument("--abi-out", required=False)
    p.add_argument("--abi-from-plugin", required=False)
    p.add_argument("--bin-path", action="append", default=[])
    p.add_argument("--bin-exe", action="append", default=[])
    p.add_argument("--extra-env-key", type=str, action="append", default=[])
    p.add_argument("--extra-env-value", type=str, action="append", default=[])
    return p


def registerer():
    p = Parser()
    p.add_argument("--ghc-pkg", required=True, type=str)
    p.add_argument("--output", required=True, type=str)
    p.add_argument("--package-conf", required=True, type=str)
    return p


WRAP_DESTS = {"abi_from_plugin": "--abi-from-plugin", "buck2_dep": "--buck2-dep", "buck2_packagedb_dep": "--buck2-packagedb-dep",
              "buck2_package_db": "--buck2-package-db", "ghc": "--ghc", "ghc_dir": "--ghc-dir",
              "ghc_argsfile": "--ghc-argsfile", "abi_out": "--abi-out", "bin_path": "--bin-path",
              "bin_exe": "--bin-exe", "extra_env_key": "--extra-env-key", "extra_env_value": "--extra-env-value"}
REG_DESTS = {"ghc_pkg": "--ghc-pkg", "output": "--output", "package_conf": "--package-conf"}


def outcome(parser, dests, argv, known):
    try:
        ns, extras = parser.parse_known_args(argv) if known else (parser.parse_args(argv), [])
    except Exit as e:
        return {"status": e.status}
    values = {}
    for dest, name in dests.items():
        v = getattr(ns, dest)
        if v is None or v == [] and name not in ("--buck2-package-db",):
            continue
        values[name] = v if isinstance(v, list) else [v]
    return {"status": 0, "values": values, "extras": extras}


VOCAB = ["--ghc", "--ghc-dir", "--ghc-d", "--ghc-a", "--ghc-", "--buck2-package-db", "--buck2-pa", "--buck2-packagedb-dep",
         "--buck2-dep", "--buck2-d", "--abi-out", "--abi-out=", "--abi-from-plugin", "--abi-f", "--abi-", "--bin-exe", "--bin-path", "--bin-", "--extra-env-key",
         "--extra-env-value", "--extra-env-v=v", "--b", "--ghc=g2", "--buck2-package-db=p", "--bin-e=e", "--other",
         "--other=1", "-c", "-o", "-package-db", "-", "--", "x", "y z", "-1", "-1.5", "-.5", "-1x", "", "+RTS",
         "-A256m", "-RTS", "a.hs", "-x y", "--ghc-pkg", "--output", "--package-conf", "--h", "-h", "--help", "--o",
         "--package-conf=c", "--ghc-p"]


def fuzz(rng, n):
    for _ in range(n):
        argv = [rng.choice(VOCAB) for _ in range(rng.randint(0, 12))]
        if rng.random() < 0.7:
            argv = ["--ghc", "g"] + argv
        yield argv


AT_FILES = {
    "plain": "--ghc\ng\n-c\nx.hs\n",
    "crlf": "--ghc\r\ng\r\n\r\n-c\r\n",
    "empty-lines": "\n\n--ghc\ng\n\n",
    "nested": "@testdata/at/plain\n--buck2-package-db\na\n@testdata/at/dbs\n",
    "dbs": "--buck2-package-db\nb\n--bin-exe\nx/y\n",
    "no-newline": "--ghc\ng",
    "spaces": "--ghc g\n -c\n",
}


# ghc_wrapper.py's check_plugin_abi_hash at buck2-haskell 290aaa39, verbatim, run over the scenarios below.
def check_plugin_abi_hash(abi_out):
    if abi_out:
        if not abi_out.exists():
            stem = abi_out.name.split(".")[0]
            siblings = sorted(
                p.name for p in abi_out.parent.glob(f"{stem}*") if p.is_file()
            )
            raise SystemExit(
                f"the oneshot plugin wrote no ABI hash at {abi_out}; "
                f"files for this module: {siblings}"
            )
        if abi_out.stat().st_size == 0:
            raise SystemExit(f"the oneshot plugin wrote an empty ABI hash at {abi_out}")


ABI_FILES = {
    "present/Foo.dyn_hi": "hi", "present/Foo.dyn_hi.hash": "0123abcd",
    "missing/Bar.dyn_hi": "hi", "missing/Bar.dyn_o": "o", "missing/Bar.hie": "hie", "missing/Bar.hs-boot.dyn_hi": "b",
    "missing/Other.dyn_hi": "x", "missing/.Bar.hidden": "h",
    "empty/Baz.dyn_hi": "hi", "empty/Baz.dyn_hi.hash": "",
    "lonely/.keep": "",
    "quote/It's.dyn_hi": "hi", "quote/It's.dyn_o": "o",
}
ABI_CASES = ["present/Foo.dyn_hi.hash", "missing/Bar.dyn_hi.hash", "empty/Baz.dyn_hi.hash", "lonely/Q.dyn_hi.hash",
             "quote/It's.dyn_hi.hash", "missing/Bar.hs-boot.dyn_hi.hash"]


def abi_cases():
    # Built in a scratch directory, not committed: go:embed refuses a name with a quote and skips dotfiles, so
    # the test recreates these files from the JSON instead.
    import tempfile
    os.chdir(tempfile.mkdtemp())
    root = "testdata/abi"
    for rel, text in ABI_FILES.items():
        os.makedirs(os.path.dirname(f"{root}/{rel}"), exist_ok=True)
        with open(f"{root}/{rel}", "w") as f:
            f.write(text)
    out = []
    for rel in ABI_CASES:
        try:
            check_plugin_abi_hash(pathlib.Path(f"{root}/{rel}"))
            out.append({"path": f"{root}/{rel}", "error": None})
        except SystemExit as e:
            out.append({"path": f"{root}/{rel}", "error": str(e.code)})
    return {"files": {f"{root}/{rel}": text for rel, text in ABI_FILES.items()}, "cases": out}


def main():
    os.makedirs("testdata/at", exist_ok=True)
    for name, text in AT_FILES.items():
        with open(f"testdata/at/{name}", "w", newline="") as f:
            f.write(text)
    rng = random.Random(20261012)
    w, r = wrapper(), registerer()
    curated = [
        ["--ghc", "g", "--buck2-package-db", "a", "--buck2-package-db", "b", "-c", "x.hs"],
        ["--ghc", "g", "--buck2-package-db", "a", "b", "-c"],
        ["--ghc", "g", "--ghc-a", "f", "--ghc-d=d", "-1", "x y", "--other", "+RTS", "-A256m", "-RTS", ""],
        ["--ghc", "g", "--", "--ghc", "h"],
        ["--ghc", "g", "--ghc-"],
        ["--ghc", "g", "--bin-exe", "-x"],
        [],
        ["@testdata/at/plain"], ["@testdata/at/crlf", "-o", "x"], ["@testdata/at/empty-lines"], ["@testdata/at/nested"],
        ["--ghc", "g", "@testdata/at/dbs", "--buck2-package-db", "c"], ["@testdata/at/no-newline"], ["@testdata/at/spaces"],
        ["--ghc", "g", "@testdata/at/missing"], ["--ghc", "g", "@"], ["--ghc", "g", "@@testdata/at/plain"],
    ]
    cases = [{"tool": "wrap", "argv": a, **outcome(w, WRAP_DESTS, a, True)} for a in curated + list(fuzz(rng, 800))]
    reg = [["--ghc-pkg", "p", "--output", "o", "--package-conf", "c"], ["--ghc-pkg", "p", "--o", "o", "--package-c=c"],
           ["--ghc-pkg", "p", "--output", "o"], ["--ghc-pkg", "p", "--output", "o", "--package-conf", "c", "extra"]]
    cases += [{"tool": "register", "argv": a, **outcome(r, REG_DESTS, a, False)} for a in reg + list(fuzz(rng, 800))]

    paths = ["", ".", "./a", "a//b", "a/./b", "a/../b", "/a", "//a", "///a", "a/", "a/b/", "./", "/", "//", "a.b",
             "x/Foo.dyn_hi.hash", "x/.hash", "x/Foo.", "x/Foo", "buck-out/v2/a/../b.hash", "a/b.c/d", "..", "a/.."]
    path_cases = [{"in": p, "path": str(pathlib.PurePosixPath(p)),
                   "dirname": os.path.dirname(str(pathlib.PurePosixPath(p))),
                   "without_suffix": (str(pathlib.PurePosixPath(p).with_suffix("")) if pathlib.PurePosixPath(p).name else None)}
                  for p in paths]
    texts = ["a\nb", "a\r\nb\r", "a\rb\n\nc", "a\x0bb\x0cc\x1cd\x1de\x1ef", "a\u0085b c d", "", "\n", "a\n",
             "x\n\ny\n"]
    line_cases = [{"in": t, "lines": t.splitlines()} for t in texts]
    here = os.getcwd()
    abi = abi_cases()
    os.chdir(here)
    json.dump({"python": sys.version.split()[0], "parse": cases, "paths": path_cases, "lines": line_cases, "abi": abi}, sys.stdout, indent=0)


main()
