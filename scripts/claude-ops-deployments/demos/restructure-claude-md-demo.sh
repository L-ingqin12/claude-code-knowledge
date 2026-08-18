#!/usr/bin/env bash
# ============================================================================
# CLAUDE.md Restructuring Demo
# ============================================================================
# Demonstrates migrating from a monolithic CLAUDE.md to an @include-based
# modular structure under .claude/.  This is a read-only demo — it creates
# sample files in /tmp/claude-md-demo/ and prints a token-usage comparison.
#
# Usage:
#   bash restructure-claude-md-demo.sh          # run demo, clean up temp dir
#   bash restructure-claude-md-demo.sh --keep    # run demo, leave temp dir
# ============================================================================
set -euo pipefail

DEMO_DIR="/tmp/claude-md-demo"
KEEP="${1:-}"  # pass --keep to leave temp dir for inspection

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
announce() { printf '\n\e[1;36m==> %s\e[0m\n' "$*"; }
sub()       { printf '  \e[1;35m->\e[0m %s\n' "$*"; }
token_line_hr() { printf '  %s\n' '────────────────────────────────────────────'; }

# rough token counter (~3 chars per token for English text)
token_est() {
  local text
  text="$(cat)"
  local chars
  chars="$(printf '%s' "$text" | wc -c)"
  printf '%d' $(( (chars + 2) / 3 ))
}

# ---------------------------------------------------------------------------
# 0. setup — clean slate
# ---------------------------------------------------------------------------
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR/project/src/components"
mkdir -p "$DEMO_DIR/project/src/api"
mkdir -p "$DEMO_DIR/project/deploy"

# Small sample files to give the project some "shape"
cat > "$DEMO_DIR/project/src/components/Header.tsx" <<'EOF'
export const Header = () => <header>Hello</header>;
EOF

cat > "$DEMO_DIR/project/src/api/handler.go" <<'EOF'
package api
func Handler() { println("ok") }
EOF

# ===========================================================================
# 1. BEFORE — monolithic CLAUDE.md
# ===========================================================================
announce "1. BEFORE — monolithic CLAUDE.md"

cat > "$DEMO_DIR/project/CLAUDE.md" <<'CLAUDE'
# Project Rules

Everything below applies globally.  Sections are separated by comments —
the AI must read *all* of them on every request, even when irrelevant.

## Security (applies everywhere)

- Never commit secrets, API keys, or tokens.
- Scan dependencies for known vulnerabilities before adding them.
- All user input must be validated and sanitized.
- Use parameterized queries for database access — never raw string interpolation.
- Enable 2FA on all production accounts.
- Run `npx audit-ci --high` before every commit.
- Report suspected breaches to security@example.com immediately.

## Frontend (applies to .tsx .jsx files)

- Use React functional components with hooks, never class components.
- Prefer TypeScript strict mode — avoid `any` and `as` casts.
- Style with Tailwind utility classes; avoid inline styles and CSS modules.
- Keep components under 200 lines; extract reusable logic into custom hooks.
- Use Next.js App Router for all new routes.
- Run `npm run lint:ts` before pushing.
- Test components with React Testing Library — prefer behavior over implementation.

## Backend (applies to .go files)

- Follow standard Go project layout conventions.
- Use `net/http` or Chi router — avoid heavy frameworks like Gin.
- All exported functions must have doc comments.
- Errors must be wrapped with context using `fmt.Errorf("...: %w", err)`.
- Use wire for dependency injection, not manual constructors.
- Run `go vet ./...` and `golangci-lint run` before committing.
- Write table-driven tests with `testing` package.

## Deploy (applies only during deploy operations)

- Deploy via GitHub Actions workflow `.github/workflows/deploy.yml`.
- Staging deploys are automatic on merge to `develop`.
- Production deploys require a manually triggered workflow with approval.
- Run database migrations as a separate step before releasing new pods.
- Rollback by reverting the merge commit and re-deploying — never hotfix.
- Monitor Datadog dashboard for 5 minutes after each deploy.
- If error rate spikes >1%, rollback immediately.

## Personal (author preferences)

- Indent with 2 spaces — never tabs.
- Maximum line length is 100 characters.
- Commit messages follow Conventional Commits format.
- Use `pnpm` instead of `npm` or `yarn`.
- Editor: VS Code with the project's recommended extensions.
- Always run `pnpm install` after switching branches.
CLAUDE

# Show the monolithic file
printf '\n'
cat "$DEMO_DIR/project/CLAUDE.md" | head -3
echo "  ..."
wc -l "$DEMO_DIR/project/CLAUDE.md" | awk '{print "  (" $1 " lines total)"}'

# ===========================================================================
# 2. AFTER — modular structure
# ===========================================================================
announce "2. AFTER — modular @include structure"

# Create the .claude directory skeleton
mkdir -p "$DEMO_DIR/project/.claude/rules"

# ---- security.md (globs: all files) -------------------------------------
cat > "$DEMO_DIR/project/.claude/rules/security.md" <<'EOF'
---
paths: ["**/*"]
---

## Security

- Never commit secrets, API keys, or tokens.
- Scan dependencies for known vulnerabilities before adding them.
- All user input must be validated and sanitized.
- Use parameterized queries for database access — never raw string interpolation.
- Enable 2FA on all production accounts.
- Run `npx audit-ci --high` before every commit.
- Report suspected breaches to security@example.com immediately.
EOF

# ---- frontend.md (globs: .tsx .jsx) -------------------------------------
cat > "$DEMO_DIR/project/.claude/rules/frontend.md" <<'EOF'
---
paths: ["**/*.tsx", "**/*.jsx"]
---

## Frontend

- Use React functional components with hooks, never class components.
- Prefer TypeScript strict mode — avoid `any` and `as` casts.
- Style with Tailwind utility classes; avoid inline styles and CSS modules.
- Keep components under 200 lines; extract reusable logic into custom hooks.
- Use Next.js App Router for all new routes.
- Run `npm run lint:ts` before pushing.
- Test components with React Testing Library — prefer behavior over implementation.
EOF

# ---- backend.md (globs: .go) --------------------------------------------
cat > "$DEMO_DIR/project/.claude/rules/backend.md" <<'EOF'
---
paths: ["**/*.go"]
---

## Backend

- Follow standard Go project layout conventions.
- Use `net/http` or Chi router — avoid heavy frameworks like Gin.
- All exported functions must have doc comments.
- Errors must be wrapped with context using `fmt.Errorf("...: %w", err)`.
- Use wire for dependency injection, not manual constructors.
- Run `go vet ./...` and `golangci-lint run` before committing.
- Write table-driven tests with `testing` package.
EOF

# ---- deploy.md (globs: none — loaded only during deploy tasks) ----------
cat > "$DEMO_DIR/project/.claude/rules/deploy.md" <<'EOF'
---
paths: []
---

## Deploy

- Deploy via GitHub Actions workflow `.github/workflows/deploy.yml`.
- Staging deploys are automatic on merge to `develop`.
- Production deploys require a manually triggered workflow with approval.
- Run database migrations as a separate step before releasing new pods.
- Rollback by reverting the merge commit and re-deploying — never hotfix.
- Monitor Datadog dashboard for 5 minutes after each deploy.
- If error rate spikes >1%, rollback immediately.
EOF

# ---- personal.md (always loaded — CLAUDE.local.md style) -----------------
cat > "$DEMO_DIR/project/.claude/rules/personal.md" <<'EOF'
## Personal preferences

- Indent with 2 spaces — never tabs.
- Maximum line length is 100 characters.
- Commit messages follow Conventional Commits format.
- Use `pnpm` instead of `npm` or `yarn`.
- Editor: VS Code with the project's recommended extensions.
- Always run `pnpm install` after switching branches.
EOF

# ---- CLAUDE.local.md (gitignored) ---------------------------------------
cat > "$DEMO_DIR/project/.claude/CLAUDE.local.md" <<'EOF'
## Machine-local overrides

These live in .claude/CLAUDE.local.md and are gitignored.
Use for machine-specific paths, local credentials, or personal
editor overrides that should never be committed.

- Local build cache dir: /tmp/project-cache
- Editor font: JetBrains Mono 14
EOF

# ---- Top-level .claude/CLAUDE.md (thin — only @include) -----------------
cat > "$DEMO_DIR/project/.claude/CLAUDE.md" <<'EOF'
# Project Rules

This file is a thin entry-point.  Rules live in `.claude/rules/*.md` and
are loaded via `@include` directives below.  The AI only loads rules
whose `paths` globs match the files in the current request context.

EOF

# Add @include lines dynamically so we can count tokens
{
  echo
  echo '@include .claude/rules/security.md'
  echo '@include .claude/rules/frontend.md'
  echo '@include .claude/rules/backend.md'
  echo '@include .claude/rules/deploy.md'
  echo '@include .claude/rules/personal.md'
} >> "$DEMO_DIR/project/.claude/CLAUDE.md"

# Show the new directory tree
printf '\n'
(
  cd "$DEMO_DIR/project"
  find .claude -type f | sort | while IFS= read -r f; do
    printf '  \e[2m%s\e[0m\n' "$f"
  done
)
sub "Top-level CLAUDE.md is now $(wc -l < "$DEMO_DIR/project/.claude/CLAUDE.md") lines (down from $(wc -l < "$DEMO_DIR/project/CLAUDE.md") lines)"

# ===========================================================================
# 3. Token comparison
# ===========================================================================
announce "3. Token comparison"

# Token count for monolithic file
mono_tokens="$(token_est < "$DEMO_DIR/project/CLAUDE.md")"

# Token count for the modular approach:
#   - .claude/CLAUDE.md (thin shell)
#   - security.md      (always loaded — paths: ["**/*"])
#   - frontend.md      (loaded when .tsx/.jsx in context)
#   - backend.md       (loaded when .go in context)
#   - deploy.md        (loaded during deploy tasks)
#   - personal.md      (always loaded — no paths restriction)

# Always-loaded files in modular setup:
mod_always="$(
  cat "$DEMO_DIR/project/.claude/CLAUDE.md"
  cat "$DEMO_DIR/project/.claude/rules/security.md"
  cat "$DEMO_DIR/project/.claude/rules/personal.md"
  cat "$DEMO_DIR/project/.claude/CLAUDE.local.md"
)"
mod_always_tokens="$(printf '%s' "$mod_always" | token_est)"

# Scenario 1: working on a Go file
mod_go="$(
  printf '%s' "$mod_always"
  cat "$DEMO_DIR/project/.claude/rules/backend.md"
)"
mod_go_tokens="$(printf '%s' "$mod_go" | token_est)"

# Scenario 2: working on a TSX component
mod_tsx="$(
  printf '%s' "$mod_always"
  cat "$DEMO_DIR/project/.claude/rules/frontend.md"
)"
mod_tsx_tokens="$(printf '%s' "$mod_tsx" | token_est)"

# Scenario 3: deploying
mod_deploy="$(
  printf '%s' "$mod_always"
  cat "$DEMO_DIR/project/.claude/rules/deploy.md"
)"
mod_deploy_tokens="$(printf '%s' "$mod_deploy" | token_est)"

# Scenario 4: full stack (Go + TSX + deploy all at once)
mod_full="$(
  printf '%s' "$mod_always"
  cat "$DEMO_DIR/project/.claude/rules/backend.md"
  cat "$DEMO_DIR/project/.claude/rules/frontend.md"
  cat "$DEMO_DIR/project/.claude/rules/deploy.md"
)"
mod_full_tokens="$(printf '%s' "$mod_full" | token_est)"

token_line_hr
printf '  %-35s %8s tokens\n' "Monolithic (always all rules)"        "$mono_tokens"
token_line_hr
printf '  %-35s %8s tokens\n' "Modular base (always-loaded)"         "$mod_always_tokens"
printf '  %-35s %8s tokens\n' "  + backend (working on *.go)"        "$mod_go_tokens"
printf '  %-35s %8s tokens\n' "  + frontend (working on *.tsx)"      "$mod_tsx_tokens"
printf '  %-35s %8s tokens\n' "  + deploy (deploy task)"             "$mod_deploy_tokens"
printf '  %-35s %8s tokens\n' "  + full stack (Go+TSX+deploy)"       "$mod_full_tokens"
token_line_hr

# Savings summary
printf '\n'
savings_go=$(( mono_tokens - mod_go_tokens ))
savings_tsx=$(( mono_tokens - mod_tsx_tokens ))
savings_deploy=$(( mono_tokens - mod_deploy_tokens ))
savings_full=$(( mono_tokens - mod_full_tokens ))

printf '  \e[32mSavings (monolithic vs modular):\e[0m\n'
printf '    Working on Go backend:     %+d tokens (%+d%%)\n' "$savings_go"  $(( savings_go * 100 / mono_tokens ))
printf '    Working on TSX frontend:   %+d tokens (%+d%%)\n' "$savings_tsx" $(( savings_tsx * 100 / mono_tokens ))
printf '    Running deploy:            %+d tokens (%+d%%)\n' "$savings_deploy" $(( savings_deploy * 100 / mono_tokens ))
printf '    Full stack (all matched):  %+d tokens (%+d%%)\n' "$savings_full" $(( savings_full * 100 / mono_tokens ))

# ===========================================================================
# 4. Print the new @include-based CLAUDE.md
# ===========================================================================
announce "4. New .claude/CLAUDE.md (the thin entry-point)"

printf '\n'
cat "$DEMO_DIR/project/.claude/CLAUDE.md"

# ===========================================================================
# 5. Print explanation of how the include mechanism works
# ===========================================================================
announce "5. How it works"

cat <<'EXPLAIN'
  The @include mechanism lets you split rules into focused files, each with
  optional path restrictions:

    .claude/CLAUDE.md              # Entry point — thin, always loaded
    @include .claude/rules/*.md    # Loaded only when path globs match

  Key benefits:
    - Smaller context window — rules irrelevant to the current file are
      skipped, saving tokens for actual code.
    - Easier maintenance — each rule file is small and focused.
    - Team-friendly — frontend, backend, and security teams each own
      their own file.  No merge conflicts on a single CLAUDE.md.
    - Conditional loading — the `paths` frontmatter in each rule file
      ensures rules only activate when relevant files are in context.
    - Local overrides — .claude/CLAUDE.local.md is gitignored; use it
      for machine-specific settings without dirtying the repo.

  Caveats:
    - Avoid circular or redundant @include chains.
    - Keep the top-level .claude/CLAUDE.md as a pure index — put
      actual rules in the files it includes.
    - Test manually by verifying which rules the AI picks up for
      different file types.
EXPLAIN

# ===========================================================================
# 6. Cleanup (unless --keep)
# ===========================================================================
bold="$(printf '\e[1m')" dim="$(printf '\e[2m')" reset="$(printf '\e[0m')"
if [ "$KEEP" = "--keep" ]; then
  printf '\n  %sTemp directory left at %s%s%s for inspection%s\n' \
    "==> " "${bold}" "$DEMO_DIR" "${reset}" "${reset}"
  printf '  tree: %sfind %s -type f | sort%s\n' "${dim}" "$DEMO_DIR" "${reset}"
else
  rm -rf "$DEMO_DIR"
  printf '\n  %sCleaned up %s%s%s%s\n' \
    "==> " "${bold}" "$DEMO_DIR" "${reset}" "${reset}"
  printf '  Pass %s--keep%s as the first argument to preserve it.\n' "${bold}" "${reset}"
fi

printf '\n\e[1;32mDone.\e[0m\n'
