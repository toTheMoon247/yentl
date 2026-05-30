# YentlShared

Swift package shared between Yentl (the consumer app) and Yentl Matchmaker (the internal app).

## What lives here

- Domain models (User, Profile, Match, Queue, etc.)
- Supabase API client
- Design tokens (colors, typography, spacing)
- Cross-app utilities

Both apps consume this package as a **local Swift package** via `File → Add Package Dependencies → Add Local…` in Xcode.

## Local development

```bash
cd shared
swift build
swift test
```

CI runs the same two commands on every PR.
