# Yentl

A human-centered dating platform: real matchmakers, not algorithms, decide who you match with.

## Documentation

- [Product scope](docs/project-scope.md)
- [Tech stack](docs/tech-stack.md)
- [Implementation plan](docs/implementation-plan.md)

## Repository layout

```
apps/
  yentl/              iOS app for users (SwiftUI) — the public consumer app
  yentl-matchmaker/   iOS app for matchmakers (SwiftUI) — internal-only
shared/               Swift package shared between both apps
supabase/             Backend — SQL migrations and edge functions
docs/                 Product and implementation documentation
.github/workflows/    CI
```

## Getting started

See [docs/implementation-plan.md](docs/implementation-plan.md) for the current phase and open tasks.

The repo is set up for **Phase 0 — Foundations**. The two iOS Xcode projects have not been created yet; see the README inside each `apps/*/` folder for setup steps.
