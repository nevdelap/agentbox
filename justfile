# The default recipe runs the same checks used by GitHub Actions.

default: ci

ci: shell-check nix-parse

shell-check:
    @set -e; \
    for f in bin/ab agentbox-entrypoint.sh install-sysbox-ubuntu.sh \
             tests/run.sh tests/smoke.sh examples/agentbox-config/setup.sh; do \
        echo "bash -n $f"; \
        bash -n "$f"; \
    done
    shellcheck -x \
        bin/ab agentbox-entrypoint.sh install-sysbox-ubuntu.sh \
        tests/run.sh tests/smoke.sh examples/agentbox-config/setup.sh
    bash tests/run.sh

nix-parse:
    nix-instantiate --parse sysbox.nix >/dev/null
