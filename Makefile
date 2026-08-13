# Deployment helpers for a self-hosted Postiz (docker-compose.prod.yaml).
# Run `make help` for the list of targets, and see DEPLOY.md for the full guide.

COMPOSE := docker compose -f docker-compose.prod.yaml

# Free disk `make image` insists on before starting. The build succeeds and
# then dies while unpacking when the disk runs out, ~40 minutes in, so the
# check is worth the false positive. Override with: make image FORCE=1
IMAGE_MIN_FREE_GB ?= 10

.DEFAULT_GOAL := help
.PHONY: help init check image up down restart logs ps pull update backup restore shell psql temporal-ui

help:
	@echo "Postiz deployment"
	@echo ""
	@echo "  make init      create .env from the template and generate secrets"
	@echo "  make check     validate .env before starting anything"
	@echo "  make image     build the app image from this branch and run that"
	@echo "  make up        start the stack (pulls images first)"
	@echo "  make down      stop the stack, keeping all data"
	@echo "  make restart   restart the stack"
	@echo "  make logs      follow the logs (SERVICE=postiz to narrow it down)"
	@echo "  make ps        show the state of every container"
	@echo "  make update    pull new images and restart"
	@echo "  make backup    dump the database and uploads into ./backups"
	@echo "  make restore   restore a dump: make restore FILE=backups/db-....sql.gz"
	@echo "  make shell     open a shell inside the postiz container"
	@echo "  make psql      open psql on the postiz database"
	@echo ""

init:
	@test ! -f .env || { echo "!! .env already exists, not touching it"; exit 1; }
	@cp .env.production.example .env
	@jwt=$$(openssl rand -hex 32); \
	 pg=$$(openssl rand -hex 24); \
	 tpg=$$(openssl rand -hex 24); \
	 sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$$jwt|" .env; \
	 sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$$pg|" .env; \
	 sed -i "s|^TEMPORAL_POSTGRES_PASSWORD=.*|TEMPORAL_POSTGRES_PASSWORD=$$tpg|" .env
	@chmod 600 .env
	@echo "-> .env created with generated secrets."
	@echo "   Now fill in MAIN_URL (the public https:// address served by the proxy)"
	@echo "   and POSTIZ_BIND (this VM's private IP, reachable from the proxy)."
	@echo "   Then run: make check && make up"

check:
	@test -f .env || { echo "!! .env not found — run: make init"; exit 1; }
	@ok=1; \
	 get() { grep -E "^$$1=" .env | tail -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$$//'; }; \
	 need() { if [ -z "$$(get $$1)" ]; then echo "!! $$1 is empty in .env — $$2"; ok=0; fi; }; \
	 need MAIN_URL "the exact public URL of the instance"; \
	 need JWT_SECRET "run: openssl rand -hex 32"; \
	 need POSTGRES_PASSWORD "run: openssl rand -hex 24"; \
	 need TEMPORAL_POSTGRES_PASSWORD "run: openssl rand -hex 24"; \
	 case "$$(get MAIN_URL)" in \
	   */) echo "!! MAIN_URL must not end with a slash"; ok=0;; \
	   http://*|https://*|"") ;; \
	   *) echo "!! MAIN_URL must start with http:// or https://"; ok=0;; \
	 esac; \
	 case "$$(get POSTIZ_BIND)" in \
	   127.0.0.1|localhost|"") echo "?? POSTIZ_BIND is on loopback — a reverse proxy on another host will not reach it";; \
	 esac; \
	 profiles=$$(get COMPOSE_PROFILES); \
	 es=$$(get TEMPORAL_ENABLE_ES); \
	 case "$$profiles" in \
	   *elasticsearch*) [ "$$es" = "true" ] || { echo "!! elasticsearch is in COMPOSE_PROFILES, so TEMPORAL_ENABLE_ES must be true"; ok=0; };; \
	   *) [ "$$es" != "true" ] || { echo "!! elasticsearch is not in COMPOSE_PROFILES, so TEMPORAL_ENABLE_ES must be false"; ok=0; };; \
	 esac; \
	 [ "$$ok" = "1" ] || exit 1; \
	 echo "-> .env looks good"

# Builds the app image from the working tree (the same Dockerfile the upstream
# release is built from) and repoints .env at it, so the instance runs this
# branch instead of ghcr.io. The tag carries the commit, so rolling back is
# just POSTIZ_VERSION=<older commit>.
# Needs ~4GB of RAM for the frontend build - see DEPLOY.md if this VM has less.
image: check
	@rev=$$(git rev-parse --short HEAD 2>/dev/null) || { echo "!! not a git checkout"; exit 1; }; \
	 test -z "$$(git status --porcelain)" || rev="$$rev-dirty"; \
	 root=$$(docker info -f '{{.DockerRootDir}}' 2>/dev/null); \
	 [ -d "$$root" ] || root=/var/lib; \
	 free=$$(df -BG --output=avail "$$root" 2>/dev/null | tail -n1 | tr -dc '0-9'); \
	 if [ -n "$$free" ] && [ "$$free" -lt "$(IMAGE_MIN_FREE_GB)" ] && [ -z "$(FORCE)" ]; then \
	   echo "!! only $${free}GB free on $$root, the image needs about $(IMAGE_MIN_FREE_GB)GB to build and unpack"; \
	   echo "   reclaim space:  docker builder prune -af && docker image prune -af"; \
	   echo "   then check:     docker system df"; \
	   echo "   or override:    make image FORCE=1"; \
	   exit 1; \
	 fi; \
	 set_env() { \
	   if grep -qE "^#? *$$1=" .env; then sed -i "s|^#\? *$$1=.*|$$1=$$2|" .env; \
	   else printf '%s=%s\n' "$$1" "$$2" >> .env; fi; }; \
	 echo "-> building postiz-local:$$rev from $$(git rev-parse --abbrev-ref HEAD)"; \
	 docker build -f Dockerfile.dev --build-arg NEXT_PUBLIC_VERSION="$$rev" \
	   -t postiz-local:$$rev . || exit 1; \
	 set_env POSTIZ_IMAGE postiz-local; \
	 set_env POSTIZ_VERSION "$$rev"; \
	 echo "-> .env now points at postiz-local:$$rev — run: make up"

up: check
	@$(MAKE) --no-print-directory pull
	$(COMPOSE) up -d --remove-orphans
	@echo "-> started. Follow the first boot with: make logs SERVICE=postiz"

down:
	$(COMPOSE) down

restart: check
	$(COMPOSE) restart

logs:
	$(COMPOSE) logs -f --tail=200 $(SERVICE)

ps:
	$(COMPOSE) ps

# A locally built app image exists nowhere to pull from, so the pull is allowed
# to fail for it - the database, Redis and Temporal images still come from a
# registry and are still updated. A genuinely missing image fails on `up`.
pull:
	@if grep -qE '^POSTIZ_IMAGE=(postiz-local|localhost/)' .env 2>/dev/null; then \
	  $(COMPOSE) pull --ignore-pull-failures; \
	else \
	  $(COMPOSE) pull; \
	fi

update: check
	@grep -qE '^POSTIZ_IMAGE=(postiz-local|localhost/)' .env 2>/dev/null && \
	  echo "?? running a locally built image — this updates the other services only; run 'make image' to rebuild the app" || true
	@$(MAKE) --no-print-directory pull
	$(COMPOSE) up -d --remove-orphans
	docker image prune -f
	@echo "-> updated"

backup: check
	@mkdir -p backups
	@ts=$$(date +%Y%m%d-%H%M%S); \
	 echo "-> dumping the database"; \
	 $(COMPOSE) exec -T postiz-postgres sh -c 'pg_dump -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"' | gzip > backups/db-$$ts.sql.gz; \
	 echo "-> archiving the uploads"; \
	 $(COMPOSE) exec -T postiz tar czf - -C /uploads . > backups/uploads-$$ts.tar.gz; \
	 echo "-> backups/db-$$ts.sql.gz and backups/uploads-$$ts.tar.gz"

restore: check
	@test -n "$(FILE)" || { echo "usage: make restore FILE=backups/db-....sql.gz"; exit 1; }
	@test -f "$(FILE)" || { echo "!! $(FILE) not found"; exit 1; }
	gunzip -c "$(FILE)" | $(COMPOSE) exec -T postiz-postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

shell:
	$(COMPOSE) exec postiz bash

psql:
	$(COMPOSE) exec postiz-postgres sh -c 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

temporal-ui:
	@echo "Add 'tools' to COMPOSE_PROFILES in .env, run make up, then from your laptop:"
	@echo "  ssh -L 8080:127.0.0.1:8080 <user>@<server>"
	@echo "and open http://127.0.0.1:8080"
