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
        if base == ".env" or (base.startswith(".env.") and base != ".env.example") or base.endswith((".pem", ".key")):
            errors.append(f"credential-like file is tracked: {name}")


for check in (check_readme_first_line, check_paths_in_docs, check_make_targets, check_makefile_paths,
              check_dockerfiles, check_migrations, check_install_order, check_no_secrets_tracked):
    check()

if errors:
    print("Repository checks failed:")
    for e in errors:
        print(" -", e)
    sys.exit(1)
print("Repository checks passed.")
