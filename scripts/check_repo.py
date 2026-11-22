"""Consistency checks that need no database server (run by CI).

* README.md starts with the line the assignment requires.
* Every relative link and every repository path mentioned in README.md and
  docs/*.md exists.
* Every `make <target>` named in the README, docs and examples exists in the Makefile.
* Every repository path mentioned in the Makefile exists.
* Every COPY source in the Dockerfiles exists.
* Migrations are numbered without gaps.
* Docker's initdb order equals scripts/setup_database.sh (004/005 after the seed).
* No .env or credential file is tracked by git.
* .gitignore covers every generated credential file and local test artefact
  (asked of `git check-ignore`), without hiding the tracked evidence files.
* The Makefile's test targets read the generated credentials from their files.
* Every plugin unit-test source is built by the Linux Makefile and by the
  Windows build script, and none relies on assert().
* The formerly published demo password is not named outside the tests that
  prove it opens no account.
* README.md has its sections, names the quick-start commands and the
  credential files, links every technical document and contains none of the
  phrases of the early draft an integration merge once restored.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
FIRST_LINE = ('A project for area 11, "Write a server plugin" for the '
              '[MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/).')
PATH_PREFIXES = ("database/", "plugin/", "scripts/", "docs/", "tests/", "docker/", "frontend/", ".github/")
GENERATED_PREFIXES = ("plugin/build/",)  # build outputs, git-ignored
OUTPUT_PREFIXES = ("docs/evidence/linux/",)  # written by `make evidence` on the machine that runs it

errors = []


def check_readme_first_line():
    first = (ROOT / "README.md").read_text(encoding="utf-8").splitlines()[0]
    if first != FIRST_LINE:
        errors.append(f"README.md first line is\n  {first!r}\nexpected\n  {FIRST_LINE!r}")


def documents_to_check():
    docs = [ROOT / "README.md"] + sorted((ROOT / "docs").glob("*.md"))
    extra = ROOT / "examples" / "README.md"
    return docs + ([extra] if extra.exists() else [])


def makefile_targets():
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    return set(re.findall(r"^([a-z0-9][a-z0-9-]*):", text, flags=re.M))


def check_make_targets():
    """`make foo` inside a code span or a fenced block must name a target the Makefile defines."""
    targets = makefile_targets()
    command = re.compile(r"(?:^|[\s;&|(])make\s+(?:-C\s+\S+\s+)?([a-z][a-z0-9-]*)")
    for doc in documents_to_check():
        in_fence = False
        for number, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("```"):
                in_fence = not in_fence
                continue
            code = line if in_fence else " ".join(re.findall(r"`([^`]+)`", line))
            if "make -C plugin" in code:      # the plugin has its own Makefile
                continue
            for name in command.findall(code):
                if name not in targets:
                    errors.append(f"{doc.relative_to(ROOT)}:{number}: `make {name}` is not a Makefile target")


def check_makefile_paths():
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    pattern = r"\b((?:docs|scripts|tests|plugin|database|docker|examples|frontend)/[\w./-]+)(\*|\.\.)?"
    for candidate, glob in sorted(set(re.findall(pattern, text))):
        candidate = candidate.rstrip(".,:;")
        if glob or ".." in candidate or candidate.endswith("/") or candidate.startswith(GENERATED_PREFIXES + OUTPUT_PREFIXES):
            continue
        if not (ROOT / candidate).exists():
            errors.append(f"Makefile mentions missing path {candidate}")


def check_paths_in_docs():
    documents = documents_to_check()
    link = re.compile(r"\]\(([^)\s]+)\)")
    code = re.compile(r"`([^`\s]+)`")
    for doc in documents:
        text = doc.read_text(encoding="utf-8")
        for target in link.findall(text):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            path = (doc.parent / target.split("#")[0]).resolve()
            if not path.exists():
                errors.append(f"{doc.relative_to(ROOT)}: broken link {target}")
        for candidate in code.findall(text):
            candidate = candidate.rstrip(".,:;")
            if (candidate.startswith(PATH_PREFIXES) and not candidate.startswith(GENERATED_PREFIXES)
                    and "*" not in candidate and "<" not in candidate):
                if not (ROOT / candidate.split(":")[0]).exists():
                    errors.append(f"{doc.relative_to(ROOT)}: mentions missing path {candidate}")


def check_dockerfiles():
    for dockerfile, context in ((ROOT / "docker/mariadb/Dockerfile", ROOT), (ROOT / "frontend/Dockerfile", ROOT / "frontend")):
        for line in dockerfile.read_text(encoding="utf-8").splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "COPY" and not parts[1].startswith("--"):
                for source in parts[1:-1]:
                    if source != "." and not (context / source).exists():
                        errors.append(f"{dockerfile.relative_to(ROOT)}: COPY source {source} missing")


def check_migrations():
    numbers = sorted(int(p.name[:3]) for p in (ROOT / "database/migrations").glob("[0-9][0-9][0-9]_*.sql"))
    if numbers != list(range(1, len(numbers) + 1)):
        errors.append(f"migration numbers are not 001..N without gaps: {numbers}")


def check_install_order():
    """Docker's initdb order equals scripts/setup_database.sh and covers every migration."""
    script_steps = []
    for line in (ROOT / "scripts/setup_database.sh").read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#"):
            continue
        for path in re.findall(r"\b(database/[\w/.-]+\.sql)\b", line):
            if path not in script_steps:
                script_steps.append(path)
    initdb = {}
    for line in (ROOT / "docker/mariadb/Dockerfile").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "COPY" and parts[2].startswith("/docker-entrypoint-initdb.d/"):
            initdb[parts[2].rsplit("/", 1)[1]] = parts[1]
    ordered = [initdb[name] for name in sorted(initdb)]
    docker_steps = [source for source in ordered if source.endswith(".sql")]
    if docker_steps != script_steps:
        errors.append("initdb order in docker/mariadb/Dockerfile differs from scripts/setup_database.sh:\n"
                      f"  Dockerfile: {docker_steps}\n  setup_database.sh: {script_steps}")
    if not ordered or ordered[-1] != "docker/mariadb/initdb/50-app-account.sh":
        errors.append("docker/mariadb/Dockerfile: the application-account initdb script must run last")
    migrations = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "database/migrations").glob("[0-9][0-9][0-9]_*.sql"))
    unlisted = [m for m in migrations if m not in script_steps]
    if unlisted:
        errors.append(f"migrations missing from the installation order: {unlisted}")
    seed = "database/seed.sql"
    for late in ("004_", "005_"):
        steps = [s for s in script_steps if s.startswith("database/migrations/" + late)]
        if seed in script_steps and steps and script_steps.index(steps[0]) < script_steps.index(seed):
            errors.append(f"{steps[0]} must run after {seed} (it corrects the seeded administrator)")


def check_no_secrets_tracked():
    try:
        tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        # Docker's test-runner context deliberately excludes .git and local
        # secrets. In that environment inspect the delivered source tree for
        # credential-like filenames instead of silently skipping the check.
        ignored = {".git", ".venv", ".venv-browser", "build", "__pycache__", ".pytest_cache"}
        names = []
        for path in ROOT.rglob("*"):
            if not path.is_file() or any(part in ignored for part in path.relative_to(ROOT).parts):
                continue
            names.append(path.relative_to(ROOT).as_posix())
    else:
        names = tracked.splitlines()
    for name in names:
        base = name.rsplit("/", 1)[-1]
        if (base == ".env" or (base.startswith(".env.") and base != ".env.example")
                or base.endswith((".pem", ".key"))
                or base.startswith(LOCAL_CREDENTIAL_FILES)
                or (base.startswith(".frantastic-") and base.endswith((".tmp", ".bak")))):
            errors.append(f"credential-like file is tracked: {name}")


# Local files that hold a generated secret (or bulky local artefacts), with the
# temporary names their writers use.  Each must be matched by .gitignore.
LOCAL_CREDENTIAL_FILES = (".admin-credentials", ".demo-credentials")
MUST_BE_IGNORED = (
    ".env", ".env.previous",
    ".admin-credentials", ".admin-credentials.pending", ".admin-credentials.tmp.Ab12Cd34",
    ".demo-credentials", ".demo-credentials.pending", ".demo-credentials.tmp.Ab12Cd34",
    ".frantastic-0123456789abcdef.tmp", ".frantastic-0123456789abcdef.bak",
    ".venv-browser/pyvenv.cfg",
    "campus_audit.jsonl", "plugin/sink_test_append.jsonl", "plugin/audit_open_test.tmp",
    "screenshots/01-home.png", "plugin/build/campus_audit.so",
)
# Tracked on purpose; an ignore rule must never hide them from `git add`.
MUST_NOT_BE_IGNORED = (
    ".env.example", "docs/evidence/sample-records.jsonl", "docs/evidence/phase1/example.jsonl",
    "docs/screenshots/01-home.png", "database/seed.sql",
)
# Without git (the Docker test-runner's build context has no .git) the rules
# are checked as text: these lines must be present in .gitignore.
REQUIRED_IGNORE_LINES = (
    ".env", ".env.*", "!.env.example", ".admin-credentials", ".admin-credentials.*",
    ".demo-credentials", ".demo-credentials.*", ".frantastic-*.tmp", ".frantastic-*.bak",
    ".venv-browser/", "*.jsonl", "audit_open_test.tmp", "!docs/evidence/**/*.jsonl",
)
# Local secrets must not reach a Docker build context either (the test-runner
# image copies the repository root).
REQUIRED_DOCKERIGNORE_LINES = (
    ".env", ".env.*", ".admin-credentials", ".admin-credentials.*",
    ".demo-credentials", ".demo-credentials.*",
)


def _git_ignores(path):
    """True/False from `git check-ignore`, or None when git cannot be asked."""
    try:
        # --no-index: judge the patterns alone, also for files that are tracked.
        result = subprocess.run(["git", "check-ignore", "--no-index", "-q", path], cwd=ROOT,
                                capture_output=True, text=True)
    except OSError:
        return None
    if result.returncode in (0, 1):
        return result.returncode == 0
    return None       # 128: not a git repository


def check_ignore_rules():
    """Generated credentials and local artefacts are git-ignored; tracked evidence is not."""
    lines = {line.strip() for line in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()}
    for required in REQUIRED_IGNORE_LINES:
        if required not in lines:
            errors.append(f".gitignore lacks the rule {required!r}")
    docker_lines = {line.strip() for line in (ROOT / ".dockerignore").read_text(encoding="utf-8").splitlines()}
    for required in REQUIRED_DOCKERIGNORE_LINES:
        if required not in docker_lines:
            errors.append(f".dockerignore lacks the rule {required!r}")
    if _git_ignores(".env") is None:
        return
    for path in MUST_BE_IGNORED:
        if _git_ignores(path) is not True:
            errors.append(f".gitignore does not ignore {path}")
    for path in MUST_NOT_BE_IGNORED:
        if _git_ignores(path) is not False:
            errors.append(f".gitignore ignores {path}, which is tracked on purpose")


def check_makefile_reads_credentials_from_files():
    """The test targets take the generated credentials from their files, never from the terminal.

    The recipe once read them with `read` and no redirection: it consumed
    standard input, so in CI (stdin empty) the administrator tests were
    silently skipped, and in a terminal `make test` waited for typed input.
    """
    text = (ROOT / "Makefile").read_text(encoding="utf-8")
    for variable, source in (("TEST_ADMIN_PASSWORD", ".admin-credentials"), ("TEST_DEMO_PASSWORD", ".demo-credentials")):
        reads = re.findall(r"read -r " + variable + r"; \}(.{0,40})", text)
        if not reads:
            errors.append(f"Makefile no longer reads {variable} for the test targets")
        for after in reads:
            if not after.startswith(" < " + source + ";"):
                errors.append(f"Makefile reads {variable} without '< {source}' (it would read the terminal)")


# The README is the first thing a newcomer and an evaluator read.  An
# integration merge once replaced it by an early draft ("In development", a
# branch table, build instructions for a directory that does not exist) and
# every check still passed.  These are the properties that draft lacked.
README_SECTIONS = (
    "## Quick start", "## Verify that it works", "## Features", "## Architecture", "## Why a MariaDB server plugin",
    "## What the plugin records", "## Database design", "## Setup in detail",
    "## Demonstration and Audit Lab", "## SQL examples", "## Experimental findings", "## Tests",
    "## Security", "## Known limitations", "## Design decisions", "## Lessons learned", "## Team",
    "## Documentation",
)
README_MUST_MENTION = (
    "MariaDB 13.0.2", "area 11", "`make up`", "frantastic.cmd up", "`make demo`", "make test",
    "`make doctor`", ".demo-credentials", ".admin-credentials", "INSTALL SONAME", "plugin_maturity=beta",
)
README_STALE_PHRASES = (
    "In development", "is planned", "not yet integrated", "are not implemented", "is not implemented",
    "puglin1", "git switch error-handling", "Repository Branches", "## Next Steps",
    "alice.student@example.edu /",
)


def check_readme_content():
    text = (ROOT / "README.md").read_text(encoding="utf-8")
    headings = set(line.strip() for line in text.splitlines() if line.startswith("## "))
    for section in README_SECTIONS:
        if section not in headings:
            errors.append(f"README.md lacks the section {section!r}")
    for phrase in README_MUST_MENTION:
        if phrase not in text:
            errors.append(f"README.md no longer mentions {phrase!r}")
    for phrase in README_STALE_PHRASES:
        if phrase in text:
            errors.append(f"README.md contains the stale phrase {phrase!r}")
    for doc in sorted((ROOT / "docs").glob("*.md")):
        if f"docs/{doc.name}" not in text:
            errors.append(f"README.md does not link docs/{doc.name}")
    for extra in ("examples/README.md", "plugin/docs/error_handling.md", "examples/skeleton_plugin/README.md"):
        if extra not in text:
            errors.append(f"README.md does not link {extra}")


def check_plugin_unit_tests():
    """Every plugin/tests/test_*.cpp is a unit test that both build scripts build and run.

    A test-named source that no build compiles is not a test, and the Windows
    script once ran four of the six programs of the Linux Makefile.
    """
    sources = sorted(p.stem for p in (ROOT / "plugin/tests").glob("test_*.cpp"))
    makefile = (ROOT / "plugin/Makefile").read_text(encoding="utf-8")
    listed = re.search(r"^UNIT_TESTS\s*=\s*((?:.*\\\n)*.*)$", makefile, flags=re.M)
    linux = sorted(listed.group(1).replace("\\\n", " ").split()) if listed else []
    script = (ROOT / "plugin/build_windows.ps1").read_text(encoding="utf-8")
    windows = sorted(set(re.findall(r'^\s*"(test_\w+)"\s*=\s*@\(', script, flags=re.M)))
    if linux != sources:
        errors.append(f"plugin/Makefile UNIT_TESTS {linux} differs from plugin/tests/test_*.cpp {sources}")
    if windows != sources:
        errors.append(f"plugin/build_windows.ps1 builds {windows}, but plugin/tests has {sources}")
    # assert() disappears when NDEBUG is defined, which the optimised Zig build
    # for Windows does: a unit test built on it passes without checking anything.
    for name in sources:
        code = "\n".join(line.split("//", 1)[0] for line in
                         (ROOT / "plugin/tests" / (name + ".cpp")).read_text(encoding="utf-8").splitlines())
        if re.search(r"\bassert\s*\(|<cassert>|<assert\.h>", code):
            errors.append(f"plugin/tests/{name}.cpp uses assert(); use explicit checks that survive NDEBUG")


# A demo password that an earlier version published.  Nothing that is run or
# read by a newcomer may advertise it again; the tests that prove it no longer
# opens any account (and this script) are the only places that name it.
PUBLISHED_DEMO_PASSWORD = "campus-demo-" + "2026"
MAY_NAME_PUBLISHED_PASSWORD = ("frontend/tests/", "tests/windows/", "docs/evidence/")


def check_no_published_demo_password():
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT).as_posix()
        if (not path.is_file() or relative.startswith((".git/", ".venv", "plugin/build/"))
                or "/__pycache__/" in relative or relative.startswith(MAY_NAME_PUBLISHED_PASSWORD)
                or path.suffix.lower() in (".png", ".jpg", ".jpeg", ".zip", ".so", ".dll", ".exe", ".pyc")):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if PUBLISHED_DEMO_PASSWORD in text:
            errors.append(f"{relative} names the formerly published demo password; "
                          "the demo credential is generated per installation (.demo-credentials)")


for check in (check_readme_first_line, check_paths_in_docs, check_make_targets, check_makefile_paths,
              check_dockerfiles, check_migrations, check_install_order, check_no_secrets_tracked,
              check_ignore_rules, check_makefile_reads_credentials_from_files, check_plugin_unit_tests,
              check_no_published_demo_password, check_readme_content):
    check()

if errors:
    print("Repository checks failed:")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("Repository checks passed.")
