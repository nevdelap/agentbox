set shell := ["bash", "-euo", "pipefail", "-c"]

DOCKERFILES := "Dockerfile examples/agentbox-config/Dockerfile"
MARKDOWN_FILES := "README.md design_docs/coding_standards.md design_docs/roles.md"
NIX_IMAGE := "nixos/nix:2.28.4"
SHELL_FILES := "bin/ab lib/lifecycle_interfaces.sh agentbox-entrypoint.sh install-sysbox-ubuntu.sh tests/run.sh tests/runtime_matrix.sh tests/smoke.sh examples/agentbox-config/setup.sh"
SHELLCHECK_LOCK := "/tmp/agentbox-shellcheck.lock"
SHELLCHECK_IMAGE := "koalaman/shellcheck:stable"
UV_ENV := "UV_CACHE_DIR=/tmp/agentbox-uv-cache UV_TOOL_DIR=/tmp/agentbox-uv-tools"
YAML_FILES := ".github/workflows/ci.yml"

# The default recipe lists the available developer and CI gates.
default:
    @just --list

_format-just:
    @just --fmt --unstable

_format-markdown:
    @{{ UV_ENV }} uv tool run --with mdformat-gfm --with mdformat-frontmatter mdformat --number {{ MARKDOWN_FILES }}

_format-nix:
    @docker run --rm -v "$PWD:/work" -w /work {{ NIX_IMAGE }} nix --extra-experimental-features 'nix-command flakes' run 'nixpkgs#nixfmt-rfc-style' -- /work/sysbox.nix

# Apply formatters; CI also requires the submitted tree to stay unchanged.
format:
    @just _format-just
    @just _format-markdown
    @just _format-nix
    @if [ "${GITHUB_ACTIONS:-}" = true ] && ! git diff --quiet -- .; then \
        echo 'formatters changed tracked files; fix them before submitting' >&2; \
        git diff --stat -- .; exit 1; \
    fi

# Enforce the repository's 60-column commit-comment rule on the current change.
commit-check:
    @if description="$(jj log -r @ -T 'description' --no-graph 2>/dev/null)"; then :; \
    elif [[ "$(git log -1 --format=%s)" == Merge\ * ]]; then \
        description=""; \
    else description="$(git log -1 --format=%B)"; fi; \
    {{ UV_ENV }} uv run --no-project python -c 'import sys; over = [(number, len(line.rstrip("\\n")), line.rstrip("\\n")) for number, line in enumerate(sys.stdin, 1) if len(line.rstrip("\\n")) > 60]; [print(f"commit description line {number} is {width} columns: {line}") for number, width, line in over]; raise SystemExit(bool(over))' <<<"$description"

_lint-docker:
    @for f in {{ DOCKERFILES }}; do \
        docker run --rm -i hadolint/hadolint:latest hadolint --failure-threshold info - < "$f"; \
    done

_lint-markdown:
    @docker run --rm -i -v "$PWD:/work:ro" -w /work ghcr.io/igorshubovych/markdownlint-cli:latest -c .markdownlint.yaml {{ MARKDOWN_FILES }}

_lint-shell:
    @exec 9>"{{ SHELLCHECK_LOCK }}"; \
    flock 9; \
    for f in {{ SHELL_FILES }}; do \
        bash -n "$f"; \
        docker run --rm -v "$PWD:/work:ro" {{ SHELLCHECK_IMAGE }} "/work/$f"; \
    done

_lint-yaml:
    @{{ UV_ENV }} uv tool run yamllint --strict -d relaxed {{ YAML_FILES }}

# Run all linters and the commit-description policy.
lint:
    @just commit-check
    @just _lint-docker
    @just _lint-markdown
    @just _lint-shell
    @just _lint-yaml

_test-nix:
    @docker run --rm -v "$PWD:/work:ro" -w /work {{ NIX_IMAGE }} nix-instantiate --parse /work/sysbox.nix >/dev/null

_test-shell:
    @bash tests/run.sh

# Run the source-based test suites.
test:
    @just _test-nix
    @just _test-shell

# The single gate for local work and GitHub Actions.
check: format lint test

# Run a recipe quietly, retaining its full output in check.log for failures.
_q target:
    #!/usr/bin/env bash
    set -uo pipefail
    echo -n "{{ target }}: "
    if just {{ target }} > check.log 2>&1; then
        echo "ok"
    else
        status=$?
        echo "FAILED: {{ target }} — tail of check.log (full log there):" >&2
        tail -n 40 check.log >&2
        exit "$status"
    fi

# Run the full gate quietly; inspect check.log only if it fails.
qcheck: (_q "check")

# Run formatting quietly; inspect check.log only if it fails.
qformat: (_q "format")

# Run linters quietly; inspect check.log only if they fail.
qlint: (_q "lint")

# Run tests quietly; inspect check.log only if they fail.
qtest: (_q "test")

# These aliases keep focused checks convenient while check remains the gate.
nix-parse: _test-nix

shell-check: _lint-shell _test-shell
