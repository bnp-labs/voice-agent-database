# =============================================================================
# voice-agent-database/postgres — convenience wrappers around README.md's
# steps. Each target is a thin wrapper, not new logic — the README is the
# source of truth for what these actually do and why; read it before running
# anything here for the first time.
# =============================================================================

APP        := voxai-pg-selfhosted
ORG        := bnp-labs
REGION     := iad
IMAGE       := registry.fly.io/voxai-pg-selfhosted:16.11-pgvector0.8.6
MPG_SOURCE_URI ?=  # set before `make migrate` — postgresql://user:pass@direct.<hash>.flympg.net/db

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build: ## Build the image locally (§2 of README — testing only, NOT for production; see build-ci)
	docker buildx build --platform linux/amd64 -t $(IMAGE) .

.PHONY: build-ci
build-ci: ## Reminder: real builds go through .github/workflows/build-and-push.yml (real amd64 hardware), not this Makefile
	@echo "Push to trigger .github/workflows/build-and-push.yml — see README.md §2 for why local builds on Apple Silicon aren't safe for this image (-march=native)."

.PHONY: push
push: ## Push a locally-built image to Fly's registry (only if you built it on real amd64 hardware)
	fly auth docker
	docker push $(IMAGE)

.PHONY: create-cluster
create-cluster: ## §3 — create the single-node cluster with backups enabled
	fly postgres create \
		--name $(APP) \
		--org $(ORG) \
		--region $(REGION) \
		--initial-cluster-size 1 \
		--vm-cpu-kind shared --vm-cpus 1 --vm-memory 1024 \
		--volume-size 10 \
		--enable-backups \
		--image-ref $(IMAGE)

.PHONY: verify-extension
verify-extension: ## §3 — confirm pgvector loads on the actual deployed cluster
	fly postgres connect -a $(APP)

.PHONY: verify-connectivity
verify-connectivity: ## §4 — MANDATORY before migrate: test 6PN reachability first
	./scripts/verify-connectivity.sh

.PHONY: backup-drill
backup-drill: ## §5 — create + list a backup on the (still-empty) cluster before trusting it with real data
	fly postgres backup create -a $(APP)
	fly postgres backup list -a $(APP)

.PHONY: migrate
migrate: ## §6 — import data from the existing MPG cluster (set MPG_SOURCE_URI first)
	./scripts/migrate-from-mpg.sh "$(MPG_SOURCE_URI)"

.PHONY: cutover
cutover: ## §7 — point voxai-api/worker/jobs at the new database
	./scripts/cutover.sh

.PHONY: check-backups
check-backups: ## §10 — ongoing: confirm backups are actually landing
	./scripts/check-backups.sh

.PHONY: proxy
proxy: ## §11 — tunnel the cluster to localhost:5432 for laptop access
	fly proxy 5432:5432 -a $(APP)

.PHONY: decommission-mpg
decommission-mpg: ## §8 — detach MPG from all three apps (does NOT delete it — do that manually once confident)
	fly mpg detach w86750817lnr3pk4 --app voxai-api
	fly mpg detach w86750817lnr3pk4 --app voxai-worker
	fly mpg detach w86750817lnr3pk4 --app voxai-jobs
	@echo "MPG detached, NOT deleted. Run 'fly mpg delete w86750817lnr3pk4' yourself once confident — see README.md §8."

.DEFAULT_GOAL := help
