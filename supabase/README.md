# Supabase

Backend infrastructure for Yentl.

## Structure

- `migrations/` — SQL files defining the database schema. Applied in alphabetical order by the Supabase CLI.
- `functions/` — Supabase Edge Functions (TypeScript / Deno). One folder per function.

## Local development

Install the [Supabase CLI](https://supabase.com/docs/guides/cli), then from the repo root:

```bash
supabase init       # First time only — generates supabase/config.toml
supabase start      # Spin up local Postgres + GoTrue + Storage in Docker
supabase db reset   # Drop the local DB and re-apply all migrations
```

## Environments

| Env     | Where it lives             |
|---------|----------------------------|
| dev     | Local via `supabase start` |
| staging | Supabase cloud (TBD)       |
| prod    | Supabase cloud (TBD)       |

Connection details for staging and prod go in `.env.*` files at the app level — never committed.
