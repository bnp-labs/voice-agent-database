# voice-agent-database / postgres

Self-hosted Postgres 16 + pgvector for the VoxAI platform on Fly.io — a
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

**Status as of 2026-08-23:** planning + a verified, working Dockerfile.
Nothing in this folder has been deployed. No Fly cluster has been created.
The existing MPG cluster (`voxai-pg`, id `w86750817lnr3pk4`) is still what
`voxai-api`/`voxai-worker`/`voxai-jobs` actually use.

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

**Not yet verified — genuinely open questions, not settled facts:**

1. **6PN private networking to a self-hosted Postgres app.** This org's Fly private networking to app-declared ports has already failed once this session (`voxai-api`'s own port was unreachable via `.internal` from other apps — confirmed on multiple apps, multiple times, only worked after switching to public URLs). Postgres clusters may route differently (a different mechanism than plain app ports), but **do not assume** — [§4](#4-verify-connectivity-before-touching-real-data) is a mandatory checkpoint before migrating real data, not an optional nice-to-have.
2. **The image built for local testing was discarded, not pushed anywhere.** Building the real deployable image is [§2](#2-build-the-image-for-real-on-real-amd64-hardware) below — do that before trying to `fly postgres create --image-ref` against it.
3. **Backup/restore has not been drilled.** `--enable-backups` provisions the mechanism; it hasn't been tested end-to-end (backup → restore → verify).

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

What it does: SSHes into `voxai-api` (already-deployed, already has network
access to test from) and attempts a raw TCP connect to
`voxai-pg-selfhosted.internal:5432`. If it fails the same way the earlier
`voxai-api` 6PN test failed this session (DNS resolves, TCP connect times
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

Sets, on `voxai-api`/`voxai-worker`/`voxai-jobs` (same scheme/endpoint
discipline already established this session — direct connection, never a
pooled one; `postgresql+asyncpg://`, never plain `postgresql://`):
```bash
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a voxai-api
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a voxai-worker
fly secrets set DATABASE_URL="postgresql+asyncpg://voice_agent:<password>@voxai-pg-selfhosted.internal:5432/voice_agent" -a voxai-jobs
```

Confirm health after each: `curl https://voxai-api.fly.dev/healthz`, check
`fly logs` on worker/jobs for clean startup, no connection errors.

---

## 8. Decommission MPG — this is the step that actually saves money

Skip this and you're paying for both clusters.

```bash
fly mpg detach w86750817lnr3pk4 --app voxai-api
fly mpg detach w86750817lnr3pk4 --app voxai-worker
fly mpg detach w86750817lnr3pk4 --app voxai-jobs
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

```bash
./scripts/check-backups.sh    # confirm backups are actually landing, not just configured
```

Do a real restore drill periodically (not just once at setup) — the same
discipline the original VPS deployment plan already established for its
own `pg_backup.sh`/`pg_restore.sh` pattern (`docs/infra/deployment_plan.md`
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
