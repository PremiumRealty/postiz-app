# Deployment helpers for a self-hosted Postiz (docker-compose.prod.yaml).
# Run `make help` for the list of targets, and see DEPLOY.md for the full guide.

COMPOSE := docker compose -f docker-compose.prod.yaml

.DEFAULT_GOAL := help
.PHONY: help init check up down restart logs ps pull update backup restore shell psql temporal-ui

help:
	@echo "Postiz deployment"
	@echo ""
	@echo "  make init      create .env from the template and generate secrets"
	@echo "  make check     validate .env before starting anything"
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

up: check
	$(COMPOSE) pull
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

pull:
	$(COMPOSE) pull

update: check
	$(COMPOSE) pull
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
