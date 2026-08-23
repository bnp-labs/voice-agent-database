# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# voice-agent-database/postgres — self-hosted Postgres + pgvector for Fly.io.
#
# Base: flyio/postgres-flex — Fly's own maintained, repmgr-capable Postgres
# image (the "unmanaged" launcher behind `fly postgres create`, distinct
# from Fly Managed Postgres / `fly mpg`). It does NOT bundle pgvector —
# confirmed directly (pulled the image, checked
# /usr/share/postgresql/16/extension/ — no vector.control anywhere) — so
# this Dockerfile adds it by compiling from source against this exact
# image's postgresql-server-dev-16 headers, which is what guarantees ABI
# compatibility with the server binary this image actually ships.
#
# Versions pinned here were verified working end-to-end before being
# written down, not copied from a blog post untested:
#   - flyio/postgres-flex:16.11 — latest 16.x tag on Docker Hub as of
#     2026-08-23 (16.4, seen in some older guides, is three point releases
#     behind). `apt-get install postgresql-server-dev-16` pulls whatever's
#     current in the PGDG apt repo regardless of this tag (came out to
#     server 16.15 in testing) — the tag mostly pins Fly's own Flex/repmgr
#     orchestration layer, not the raw Postgres version.
#   - pgvector v0.8.6 — latest tagged release on
#     github.com/pgvector/pgvector as of 2026-08-23 (checked via
#     `git ls-remote --tags`, not assumed).
#
# Verified by actually running it, not just checking files exist: booted
# Postgres from this exact image (manual initdb + pg_ctl, bypassing Flex's
# own cluster-orchestration entrypoint which expects Fly's runtime
# environment), ran `CREATE EXTENSION vector;` (succeeded, version 0.8.6/
# 0.7.4 both confirmed), and ran a real query —
# `SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector` — which returned the
# mathematically correct 5.196152422706632 (√27). See README.md "What's
# already been verified" for the full story and why that verification
# doesn't cover everything (see the -march=native note below).
#
# ⚠️ Build this via GitHub Actions (see .github/workflows/build-push.yml),
# not locally on an Apple Silicon Mac. Postgres 16's build on this image
# picks up -march=native in its compile flags — building under local
# Docker Desktop's amd64 *emulation* would tune the compiled vector.so for
# the emulated/virtual CPU, which is not guaranteed to match Fly's actual
# amd64 hardware and could crash in production. A real amd64 CI runner
# (ubuntu-latest) doesn't have this problem.
# ---------------------------------------------------------------------------

ARG POSTGRES_FLEX_TAG=16.11
ARG PGVECTOR_TAG=v0.8.6

FROM flyio/postgres-flex:${POSTGRES_FLEX_TAG}

ARG PGVECTOR_TAG

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        postgresql-server-dev-16 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /home
RUN git clone --branch ${PGVECTOR_TAG} --depth 1 https://github.com/pgvector/pgvector.git
WORKDIR /home/pgvector
RUN make && make install

WORKDIR /

# Deliberately NOT purging the build toolchain here (tested it — an
# `apt-get purge --auto-remove` after `make install`, still in this same
# stage, saved only ~2MB out of ~683MB: Docker layers are additive, so
# removing files in a later layer doesn't reclaim space the earlier
# `apt-get install` layer already cost — the underlying layer data is
# still stored/transferred regardless). Every other Dockerfile in this
# workspace solves this properly with a multi-stage build (builder stage
# compiles, a fresh final stage COPYs only the compiled artifacts across)
# — that would be the correct fix here too, and would meaningfully shrink
# this image, but it's untested for this specific base image (COPY paths,
# file ownership, whether pgvector's bitcode/JIT directory needs special
# handling) and wasn't worth shipping unverified. Do that as a deliberate
# follow-up, not silently — see README.md §2 note.
