#!/bin/bash
# Points this clone at the versioned git hooks in scripts/hooks (pre-commit: quick check, pre-push: verify --quick).
# It changes the git configuration of this clone (core.hooksPath), so it is run by the owner, never by the assistant.
source "$(dirname "$0")/lib/common.sh"
cd "$ROOT"
chmod +x scripts/hooks/*
git config core.hooksPath scripts/hooks
log "git hooks installed (core.hooksPath = scripts/hooks)"
