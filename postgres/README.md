# voice-agent-database / postgres

Self-hosted Postgres 16 + pgvector for the Vocetto platform on Fly.io — a
cost-optimized replacement for Fly Managed Postgres (MPG). This folder is
everything needed to build the image, stand up the cluster, migrate off
MPG, verify it, and connect to it (from the platform's other Fly apps and
from your own laptop).

**Cost, why this exists at all:** MPG Basic runs ~$38/mo + ~$0.28/GB-month
storage (~$41–44/mo all-in for a small instance). A self-hosted single-node
cluster on a shared-cpu-1x/1GB machine + a small volume runs roughly
$7–11/mo — about a 70–75% cut. The tradeoff: you own backups, HA, and
Postgres upgrades yourself instead of Fly managing them. See
[§9 What you're giving up](#9-what-youre-giving-up-vs-mpg) before deciding
this is worth it for your situation.

**Status as of 2026-08-24: cutover is complete.** `voxai-pg-selfhosted` is
deployed and is what `vocetto-api`/`vocetto-worker`/`vocetto-jobs` actually use in
the Fly dev/test environment — the old MPG cluster (`vocetto-pg`, id
`w86750817lnr3pk4`) has been fully decommissioned (§8). This supersedes the
"nothing deployed yet" framing that the rest of this README (written
2026-08-23, mid-migration) was drafted against — the steps below are now a
record of what was done, not a forward-looking plan. Note this remains the
platform's **dev/test** database; Azure is the intended future production
target (not started) — see the workspace root `CLAUDE.md`.

**Update 2026-09-27 — generic replacement cluster stood up, data fully
copied, cutover blocked only on credential creation.** A new Fly Postgres
cluster, `selfhost-database`, was created (same image, same
`iad`/shared-cpu-1x/1024MB/10GB spec as `voxai-pg-selfhosted`) with a
deliberately generic name so it can host any project's Postgres going
forward, not just this platform's. All data lives in a database on that
cluster named **`vocetto_db`** (not `postgres`, and not `voice_agent` —
the app-specific name from the old cluster was deliberately dropped in
favor of the platform's new brand name, per Ambuj's request), copied via
`pg_dump`/restore through `fly ssh console`'s local-socket peer auth (no
network password needed at any point, nothing left `.internal` on either
cluster).

Copy went in two passes: first the non-client-specific reference/catalog
tables (`providers`, `billing_plans`, `billing_components`,
`billing_component_prices`, `plan_components`, `simulation_personas`,
`alembic_version`), then — after explicit confirmation, since this moves
real customer data — the remaining 56 client tables (`workspaces`,
`users`, `calls`, `agents`, everything else). Row counts verified to match
exactly (`api_audit_logs` 2003/2003, `call_events` 161/161, etc.).
`platform_provider_credentials` was intentionally left empty — it holds
real provider API keys, not just catalog data, and re-keying that is a
separate decision. An accidental copy of Fly's own `repmgr` cluster-
management schema (4 internal tables, native to `selfhost-database`'s own
fresh cluster init, picked up when the first pass dumped/restored the
whole `postgres` database) was found and dropped from `vocetto_db` — it's
not part of the app schema.

Two schema quirks hit along the way, both circular-FK pairs that a
`pg_dump --data-only` restore can't handle directly (not `DEFERRABLE`):
`billing_components.active_price_id` ↔ `billing_component_prices`, and
(in the client-data pass) `workspaces` ↔ `agents`, `agents` ↔
`agent_versions`, `calls` ↔ `batch_call_targets`, `calls` ↔
`simulation_runs`. Fix each time: `ALTER TABLE ... DROP CONSTRAINT
<name>`, load the data, then `ADD CONSTRAINT` back with the original
definition.

**What's left, and why it's not done yet:** the app-level role services
would actually connect with doesn't exist on `selfhost-database` yet.
Creating a new DB credential (and setting it into a live `fly secrets`
value) is something this session's own sandbox refuses to do — it treats
agent-created/handled database credentials as out of bounds, independent
of user go-ahead in chat. **Role name decided: `admin`**, generic across
whatever else eventually shares this cluster — explicitly not
`voice_agent`, since that's this one project's name and the whole point
of `selfhost-database` is to not be project-specific. Ambuj needs to run
this himself (`fly postgres connect -a selfhost-database` or `fly ssh
console -a selfhost-database`):

```sql
CREATE ROLE admin WITH LOGIN PASSWORD '<pick one>';
GRANT ALL PRIVILEGES ON DATABASE vocetto_db TO admin;
GRANT ALL ON ALL TABLES IN SCHEMA public TO admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO admin;
```

**This block alone is not enough — confirmed the hard way (2026-09-28,
`vocetto-api` deploy failure, see the error table below).** `GRANT ALL ON
ALL TABLES` grants DML (SELECT/INSERT/UPDATE/DELETE/etc.), never ownership
— and Postgres requires *ownership* (or superuser) to run DDL (`ALTER
TABLE`, `DROP CONSTRAINT`, ...), which every Alembic migration doing more
than a data-only `INSERT`/`UPDATE` needs. The `pg_dump`/restore in this
section ran via `fly ssh console`'s local-socket peer auth, which
connects as the cluster's `postgres` superuser — every table/sequence it
restored is therefore still **owned by `postgres`**, not `admin`,
regardless of the grants above.

The obvious one-liner, `REASSIGN OWNED BY postgres TO admin;`, **does not
work here** — confirmed: it fails with `cannot reassign ownership of
objects owned by role "postgres" because they are required by the
database system`. Root cause not fully pinned down (no `pg_shdepend`
pinned-dependency row was found tied to `postgres` or to any of its owned
tables directly — this cluster's `REASSIGN OWNED` apparently balks at
something else system-level owned by `postgres` cluster-wide, not
anything specific to `vocetto_db`'s app tables), and not worth losing more
time chasing since there's a working alternative: reassign ownership
**per object type**, scoped to `public`, instead of the blanket
cluster-wide sweep `REASSIGN OWNED` performs. Run via `fly postgres
connect -a selfhost-database` (interactive — a multi-line `DO` block
through `fly ssh console -C "..."`'s shell-escaping is not worth fighting),
`\c vocetto_db` first, then:

```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT tablename FROM pg_tables WHERE schemaname='public' AND tableowner='postgres' LOOP
    EXECUTE format('ALTER TABLE public.%I OWNER TO admin', r.tablename);
  END LOOP;
  FOR r IN SELECT sequencename FROM pg_sequences WHERE schemaname='public' AND sequenceowner='postgres' LOOP
    EXECUTE format('ALTER SEQUENCE public.%I OWNER TO admin', r.sequencename);
  END LOOP;
  FOR r IN SELECT viewname FROM pg_views WHERE schemaname='public' AND viewowner='postgres' LOOP
    EXECUTE format('ALTER VIEW public.%I OWNER TO admin', r.viewname);
  END LOOP;
END $$;
```

`ALTER TABLE/SEQUENCE/VIEW ... OWNER TO` reassigns exactly the one named
object, with none of `REASSIGN OWNED`'s cluster-wide pinned-object check —
confirmed there's nothing pinned about any individual app table (the
earlier per-role/per-object `pg_shdepend` checks came back empty), so this
path avoids whatever `REASSIGN OWNED` was tripping on entirely. Indexes
are deliberately not touched — they don't need independent ownership for
`ALTER TABLE ... DROP CONSTRAINT` (a table-level operation) to work, and
Postgres cascades a table's own index ownership when the table's owner
changes for indexes created as part of that table (e.g. a primary key).
Verify before/after:

```sql
SELECT tablename, tableowner FROM pg_tables WHERE schemaname = 'public' AND tableowner != 'admin';
SELECT sequencename, sequenceowner FROM pg_sequences WHERE schemaname = 'public' AND sequenceowner != 'admin';
```
Both should return zero rows once done.

Then, per service:
```bash
fly secrets set DATABASE_URL="postgresql+asyncpg://admin:<password>@selfhost-database.internal:5432/vocetto_db" -a vocetto-api
fly secrets set DATABASE_URL="postgresql+asyncpg://admin:<password>@selfhost-database.internal:5432/vocetto_db" -a vocetto-worker
fly secrets set DATABASE_URL="postgresql+asyncpg://admin:<password>@selfhost-database.internal:5432/vocetto_db" -a vocetto-jobs
```

`voxai-pg-selfhosted` has been left running untouched throughout, as the
live/rollback source — nothing currently points at `selfhost-database` yet.

---

## 0. What's already been verified, and what hasn't

Verified for real, not assumed, before this README was written:

| Claim | How it was checked |
|---|---|
| `flyio/postgres-flex` does **not** bundle pgvector | Pulled the image, listed `/usr/share/postgresql/16/extension/*.control` directly — no `vector.control`. |
| `16.11` is the latest `16.x` tag (not `16.4`, seen in some older guides) | Queried Docker Hub's tag API for `flyio/postgres-flex` directly. |
| `v0.8.6` is pgvector's latest release (not `v0.7.4`) | `git ls-remote --tags` against the real pgvector repo. |
| The Dockerfile in this folder actually compiles pgvector against this exact image's Postgres build | Built it locally (`docker buildx build --platform linux/amd64`), both against `v0.7.4` and `v0.8.6` — both succeeded. |
| The compiled extension actually **works**, not just "the file exists" | Booted Postgres manually inside the built image (bypassing Flex's own cluster-orchestration entrypoint, which expects Fly's runtime env) via `initdb` + `pg_ctl`, ran `CREATE EXTENSION vector;` (succeeded, correct version), then ran `SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector` and got the mathematically correct `5.196152422706632` (√27). |

**Resolved since cutover (2026-08-24):**

1. ~~6PN private networking to a self-hosted Postgres app~~ — resolved:
   `voxai-pg-selfhosted` is live and reachable from `vocetto-api`/`worker`/
   `jobs`, working fine as of the cutover. Whatever mechanism Postgres
   clusters use apparently didn't hit the same `.internal` routing failure
   plain app ports did.
2. ~~Image built for local testing was discarded~~ — resolved: the real
   image was built and pushed per [§2](#2-build-the-image-for-real-on-real-amd64-hardware), cluster created per [§3](#3-create-the-cluster).

**Still genuinely open — not settled facts:**

3. **Backup/restore has not been drilled.** `--enable-backups` provisions the mechanism; it hasn't been tested end-to-end (backup → restore → verify). Do this before trusting it in an incident.

**Real errors hit going through this guide, and the actual fixes** (kept
here so the next person doesn't re-derive these from scratch):

| Error | Cause | Fix |
|---|---|---|
| `docker push registry.fly.io/...`: `unknown: app repository not found` | `registry.fly.io/<name>` only exists once a Fly app named `<name>` exists — `fly postgres create` (§3) hadn't run yet | Push to GHCR instead (§2) — already fixed in this repo |
| `fly postgres create`: `failed to get manifest ...: unauthorized` | GHCR package defaults to **private** on first push; Fly can't authenticate to a private third-party registry | Make the package public — **not** the repo's visibility, the package's own settings: `github.com/orgs/bnp-labs/packages/container/voxai-pg-selfhosted/settings` → Change visibility |
| `fly postgres create`: `manifest unknown [http 404]` after the package was already public | The workflow's tag-construction concatenated the `pgvector_tag` input (`v0.8.6`, with the `v` — needed for `git clone --branch`) directly into the image tag, producing `pgvectorv0.8.6` — a tag nothing else in this repo referenced (everywhere else says `pgvector0.8.6`, no `v`) | Fixed in `.github/workflows/build-and-push.yml` — strips the leading `v` before building the final tag string, in its own step |
| `fly postgres create` failed mid-provision (`failed to launch VM: ... manifest ...`), left a `pending` app + an orphaned, still-billing 10GB volume behind | Fly doesn't clean up automatically on a failed create | `fly apps destroy <name>` removes the app **and** its volume in one step — confirmed empty afterward with `fly volumes list`. Don't assume a failed create leaves nothing behind; check before retrying. |
| `fly postgres import`: `region code must be specified when not running interactively`, then (after adding `--region`) `prompt: non interactive` | The import spins up a temporary migration machine and normally prompts for region + VM size — both need explicit flags in a non-interactive/scripted context | Add `--region iad --vm-size shared-cpu-1x` (or your region/size) to the import command |
| `fly postgres import --create=false` reported `Import complete!`, but the target database (`voice_agent`, matching the source URI's path) had zero tables | `--create=false` doesn't target the database named in the source URI — it silently imports into the target cluster's **default** `postgres` database instead | Use `postgres` as the database name in `DATABASE_URL`, not `voice_agent` — confirmed by checking `postgres` directly (52 tables, real data, including the "Ambuj Workspace" row) after `voice_agent` came up empty. `cutover.sh`'s default was updated accordingly. If you want the `voice_agent` name specifically, migrate the data again with `--create=true` instead (untested here — go with `postgres` unless the name genuinely matters to you). |
| `vocetto-api` Fly deploy: `ProgrammingError: ... InsufficientPrivilegeError: must be owner of table calls` on `ALTER TABLE calls DROP CONSTRAINT ...` (2026-09-28, first DDL-doing Alembic migration since cutover to `selfhost-database`) | `GRANT ALL ON ALL TABLES` (§0 "What's left" block) grants DML only — the `pg_dump`/restore ran as the `postgres` superuser via peer auth, so `admin` was never the owner, just grantee. Confirmed via `SELECT tablename, tableowner FROM pg_tables`: every table owned by `postgres`. Deploy itself was safe — Fly kept the previous healthy machine serving, no outage — but blocks any future migration doing `ALTER TABLE`/`DROP CONSTRAINT`/etc. | Per-object `ALTER TABLE/SEQUENCE/VIEW ... OWNER TO admin` loop (§0's `DO $$` block above) — **not** `REASSIGN OWNED BY postgres TO admin`, see next row. |
| `REASSIGN OWNED BY postgres TO admin;` (the obvious fix for the row above): `ERROR: cannot reassign ownership of objects owned by role "postgres" because they are required by the database system` | Not fully root-caused — no `pg_shdepend` row pins `postgres` itself or any individual `vocetto_db` app table (checked directly), so `REASSIGN OWNED`'s cluster-wide sweep is tripping on something else `postgres` owns outside this database's app tables. Not worth chasing further since a working alternative exists. | Reassign ownership per object (`ALTER TABLE`/`ALTER SEQUENCE`/`ALTER VIEW ... OWNER TO`) instead of the blanket `REASSIGN OWNED` — see the `DO $$` block in §0 above. |

---

## 1. Folder contents

`voice-agent-database` is the GitHub repo itself — `postgres/` is a
subfolder within it (room for `redis/` or others alongside it later, same
idea as `voice-agent-infra` holding multiple concerns). **`.github/` lives
at the repo root**, one level above `postgres/`, not inside it — GitHub
only ever discovers workflows at `.github/workflows/` relative to the repo
root; nested anywhere else, they're silently never triggered. Got this
wrong once already this session (had it nested inside `postgres/`) — fixed,
noted here so it doesn't happen again next time a folder gets added.

```
voice-agent-database/                  # repo root
├── .github/workflows/
│   └── build-and-push.yml            # builds on REAL amd64 (not emulated), pushes to GHCR
│                                       # context: postgres — Dockerfile lives one level down
└── postgres/
    ├── README.md                     # this file — the step-by-step guide
    ├── Dockerfile                    # verified: flyio/postgres-flex + pgvector
    ├── Makefile                      # convenience wrappers around the steps below
    ├── .dockerignore
    └── scripts/
        ├── verify-connectivity.sh    # §4 — 6PN reachability + pgvector check, before migrating
        ├── migrate-from-mpg.sh       # §6 — wraps `fly postgres import`
        ├── cutover.sh                # §7 — points api/worker/jobs at the new DB
        └── check-backups.sh          # §10 — confirms backups are actually landing
```

---

## 2. Build the image — for real, on real amd64 hardware

**Image size note:** this Dockerfile is single-stage and ~683MB (mostly the
build toolchain it doesn't need at runtime). Tested removing it with
`apt-get purge --auto-remove` in a later layer — saved only ~2MB, because
Docker layers are additive; deleting a file in a later layer doesn't
reclaim the space an earlier layer already cost. A proper multi-stage
build (builder stage compiles, a fresh final stage `COPY`s only the
compiled `vector.so`/`vector.control`/SQL files across — the same pattern
every other Dockerfile in this workspace already uses) would meaningfully
shrink this. Not done here — untested for this specific base image and not
worth shipping unverified — but it's the right next optimization if image
size/pull time ever matters enough to justify testing it properly.


**Do not build this locally on an Apple Silicon Mac and deploy that image.**
Verified during testing: Postgres 16's build on this image compiles with
`-march=native` in its flags. Built under Docker Desktop's amd64
*emulation* (QEMU), that tunes the compiled `vector.so` for the emulated
virtual CPU — not guaranteed to match Fly's actual amd64 hardware, and a
mismatch here means a crash in production, not a build error you'd catch
locally. A real amd64 CI runner doesn't have this problem.

**Push target is GHCR, not `registry.fly.io` — this is not optional, it's
the fix for a real error.** `registry.fly.io/<name>` is a per-app
namespace that only exists once an app named `<name>` already exists in
your org — and at this point in the guide, `fly postgres create` (§3)
hasn't run yet, so that app doesn't exist. Confirmed by hitting it for
real: `docker push registry.fly.io/voxai-pg-selfhosted:...` fails with
`unknown: app repository not found` before the app exists. Push to GHCR
(public) instead, and `fly postgres create --image-ref` pulls from there
in §3 — this is also what Fly's own community recommends for this exact
scenario.

**The GHCR package must be set to PUBLIC after the first push** — Fly's
infrastructure can't authenticate to pull a private third-party registry
image (this bit the platform's own application images earlier this
session, same underlying limitation). One-time: GitHub → `bnp-labs` org →
Packages → `voxai-pg-selfhosted` → Package settings → Change visibility →
Public.

Use the provided GitHub Actions workflow — same pattern already used for
every other service's CI in this workspace (`docker/build-push-action`,
`docker/login-action`), just building this instead of an app:

```bash
cd voice-agent-database   # repo root — not postgres/, .github/ lives here (see §1)
git push origin main
gh workflow run build-and-push.yml -R bnp-labs/voice-agent-database \
  -f postgres_flex_tag=16.11 -f pgvector_tag=v0.8.6
```
(No new GitHub secret needed beyond the automatic `GITHUB_TOKEN` — GHCR
push auth uses that, unlike the `registry.fly.io` approach this replaces
which would have needed `FLY_API_TOKEN` for `fly auth docker`.)

Or manually, from a real amd64 machine (a Linux CI box, not your Mac):
```bash
docker login ghcr.io -u <your-github-username>   # PAT with write:packages
docker buildx build --platform linux/amd64 \
  -t ghcr.io/bnp-labs/voxai-pg-selfhosted:16.11-pgvector0.8.6 \
  --push .
```

---

## 3. Create the cluster

Single node (cheapest — no HA replica), sized comparably to MPG Basic,
backups on from the start, using the custom image from §2:

```bash
fly postgres create \
  --name voxai-pg-selfhosted \
  --org bnp-labs \
  --region iad \
  --initial-cluster-size 1 \
  --vm-cpu-kind shared --vm-cpus 1 --vm-memory 1024 \
  --volume-size 10 \
  --enable-backups \
  --image-ref ghcr.io/bnp-labs/voxai-pg-selfhosted:16.11-pgvector0.8.6
```

`--enable-backups` provisions a Tigris (Fly's S3-compatible storage)
bucket and turns on WAL-based backups automatically — this is what closes
most of the "you lose MPG's managed backups" gap. `--initial-cluster-size 1`
is the actual cost lever; add replicas later (`fly postgres` cluster-resize
commands) if you ever want HA back, at the cost of undoing part of the
savings.

Confirm pgvector is actually there on the running cluster (belt-and-braces
— the image build already proved this works, but confirm the deployed
instance too):
```bash
fly postgres connect -a voxai-pg-selfhosted
# inside psql:
CREATE EXTENSION IF NOT EXISTS vector;
SELECT extversion FROM pg_extension WHERE extname = 'vector';
```

---

## 4. Verify connectivity before touching real data

**This is the step that answers the open question from §0.1.** Don't skip
it, and don't do §6 (migration) until it passes.

```bash
./scripts/verify-connectivity.sh
```

What it does: SSHes into `vocetto-api` (already-deployed, already has network
access to test from) and attempts a raw TCP connect to
`voxai-pg-selfhosted.internal:5432`. If it fails the same way the earlier
`vocetto-api` 6PN test failed this session (DNS resolves, TCP connect times
out), **stop** — the rest of this guide's `.internal` hostnames won't work,
and you need a different connectivity approach (a `fly proxy`-based
sidecar, or investigating whether Postgres clusters use a different private
routing mechanism than plain apps) before going further.

---

## 5. (Optional but recommended) Drill a backup/restore before you trust it

An untested backup isn't a backup. Before migrating real data onto this
cluster, prove the backup mechanism actually works on this empty cluster
first — cheap to test now, expensive to discover it doesn't work later:
```bash
fly postgres backup create -a voxai-pg-selfhosted
fly postgres backup list -a voxai-pg-selfhosted
# then actually try a restore into a throwaway cluster and confirm it worked
```

---

## 6. Migrate data from the existing MPG cluster

```bash
./scripts/migrate-from-mpg.sh
```

Wraps:
```bash
fly postgres import \
  "postgresql://voice_agent:<password>@direct.w86750817lnr3pk4.flympg.net/voice_agent" \
  -a voxai-pg-selfhosted
```
Runs as a one-off Fly migration machine — schema + data in one step. After
it finishes, spot-check that row counts / a few known rows (e.g. the
"Ambuj Workspace" row) match between old and new before proceeding.

---

## 7. Cutover — point the three apps at the new database

```bash
./scripts/cutover.sh
```

Sets, on `vocetto-api`/`vocetto-worker`/`vocetto-jobs` (same scheme/endpoint
discipline already established this session — direct connection, never a
pooled one; `postgresql+asyncpg://`, never plain `postgresql://`):
```bash
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a vocetto-api
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a vocetto-worker
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a vocetto-jobs
```

Confirm health after each: `curl https://vocetto-api.fly.dev/healthz`, check
`fly logs` on worker/jobs for clean startup, no connection errors.

---

## 8. Decommission MPG — this is the step that actually saves money

Skip this and you're paying for both clusters.

```bash
fly mpg detach w86750817lnr3pk4 --app vocetto-api
fly mpg detach w86750817lnr3pk4 --app vocetto-worker
fly mpg detach w86750817lnr3pk4 --app vocetto-jobs
```

**Sit on the still-undeleted MPG cluster for a few days** as a rollback
safety net before the final delete — a brief period paying for both is
worth it versus no fallback if something's wrong with the new setup.
```bash
# only once fully confident:
fly mpg delete w86750817lnr3pk4
```

---

## 9. What you're giving up vs. MPG

| MPG gives you | Self-hosted equivalent | Effort to replicate |
|---|---|---|
| Managed backups | `--enable-backups` (Tigris/WAL) | Low — built into `fly postgres create`, but drill a restore (§5) |
| High availability / automatic failover | None at `--initial-cluster-size 1` | Real gap — a single-node volume has no redundancy; a host failure means restoring from backup, not automatic failover |
| Connection pooling | None built-in | Not actually a loss — the app already does its own SQLAlchemy pooling, and PgBouncer was already found to fight with asyncpg (see the earlier timezone/DB debugging in this session) |
| Postgres version upgrades handled for you | You run them | Real ongoing ops burden |
| Fly Support covers it | Explicitly **not** supported — `fly postgres create`'s own help text says so | You're on your own for anything below the Fly-platform layer |

---

## 10. Ongoing maintenance

**Status: commands below not yet confirmed run against the live
`voxai-pg-selfhosted` cluster** — see `docs/platform/known-issues.md` Tier 1 #3 in
the workspace root. This was the root fix for the 2026-08-23 incident (which
happened on the then-live MPG cluster); run it here now that
`voxai-pg-selfhosted` is the actual live database. Needs to be run directly
by Ambuj (`ALTER DATABASE` has tripped the agent permission classifier
before) — update this status line once done.

### Session/lock timeouts — set this once, right after cluster creation

Fresh `flyio/postgres-flex` clusters ship with `idle_in_transaction_session_timeout`,
`statement_timeout`, and `lock_timeout` all disabled (`0` — no limit). That
bit vocetto-api on 2026-08-23: an app-side connection got left `idle in
transaction` (see `db/session.py`'s `get_session()` for the app-level
hardening that's the other half of this fix), holding row locks on
`sessions` for **over an hour**, with nothing on the Postgres side to kill
it. Every other request touching `sessions` — i.e. almost every
authenticated request — queued behind it until the app's own connection
pool filled up and started timing out. Run this against every new cluster,
not just this one:

```bash
fly ssh console -a voxai-pg-selfhosted -C "psql -U postgres -h /var/run/postgresql -p 5433 -d postgres -c \"ALTER DATABASE postgres SET idle_in_transaction_session_timeout = '60s';\""
fly ssh console -a voxai-pg-selfhosted -C "psql -U postgres -h /var/run/postgresql -p 5433 -d postgres -c \"ALTER DATABASE postgres SET lock_timeout = '15s';\""
```

`idle_in_transaction_session_timeout=60s` is the one that matters most: it
guarantees a leaked/stuck transaction can never sit longer than 60s
regardless of *why* it got stuck — a safety net independent of whatever
application bug (or the next one) causes it. It's safe to set aggressively;
it only fires when a session is truly idle (no query running) inside an
open transaction, which should never legitimately last more than
milliseconds between statements in the same transaction — it cannot kill a
query that's actually executing. `lock_timeout=15s` fails a query fast if
it's stuck waiting on someone else's lock, instead of queueing silently.

Deliberately **not** setting `statement_timeout` cluster-wide: it bounds
genuinely slow-but-legitimate queries too (analytics/billing rollups scan a
7-day window; KB ingestion embeds real documents), and a wrong global value
risks killing real work instead of just stuck ones. If a specific workload
needs it, set it per-session in that code path, not globally.

Verify what's active any time:
```bash
fly ssh console -a voxai-pg-selfhosted -C "psql -U postgres -h /var/run/postgresql -p 5433 -d postgres -c \"SHOW idle_in_transaction_session_timeout;\""
```

Check for a stuck session right now (also surfaced by `voice-agent-api doctor`'s `stuck_transactions` check):
```bash
fly ssh console -a voxai-pg-selfhosted -C "psql -U postgres -h /var/run/postgresql -p 5433 -d postgres -c \"SELECT pid, state, now()-xact_start AS stuck_for FROM pg_stat_activity WHERE state = 'idle in transaction';\""
```

```bash
./scripts/check-backups.sh    # confirm backups are actually landing, not just configured
```

Do a real restore drill periodically (not just once at setup) — the same
discipline the original VPS deployment plan already established for its
own `pg_backup.sh`/`pg_restore.sh` pattern (`docs/archive/vps-deployment-plan.md`
§11 in the workspace root), reused here instead of reinvented.

---

## 11. Accessing this database from your laptop

```bash
fly proxy 5432:5432 -a voxai-pg-selfhosted
```
Opens a WireGuard tunnel, binds `localhost:5432` to the cluster's real
`5432`. While that's running, connect with `psql`, TablePlus, Postico,
DBeaver, or any other local tool:
```
postgresql://voice_agent:<password>@localhost:5432/voice_agent
```

---

## 12. Version pins — why these, and how to bump them later

| Component | Pinned version | Source of truth for "latest" |
|---|---|---|
| `flyio/postgres-flex` | `16.11` | `curl https://hub.docker.com/v2/repositories/flyio/postgres-flex/tags` |
| `pgvector` | `v0.8.6` | `git ls-remote --tags https://github.com/pgvector/pgvector.git` |

Both were the actual latest available as of 2026-08-23, checked directly
rather than assumed — re-check both before rebuilding this image later,
don't just bump numbers blindly. A jump to Postgres **17** is a separate,
bigger decision (major-version upgrade, not just a point release) — this
guide deliberately stays on 16.x to match what the platform's schema was
built and tested against; revisit that as its own decision later if wanted.
