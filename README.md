# voice-agent-database

Self-hosted database infrastructure for the Vocetto platform — one subfolder
per engine.

| Folder | What |
|---|---|
| [`postgres/`](postgres/README.md) | Self-hosted Postgres 16 + pgvector on Fly.io, replacing Fly Managed Postgres. Start there for the full step-by-step guide. |

`.github/workflows/` lives at this repo root (not inside `postgres/`) —
required for GitHub to discover it at all; see `postgres/README.md` §1 if
another engine folder gets added here later and this trips someone up again.
