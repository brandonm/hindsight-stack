# Hindsight stack — common operations. `make help` lists targets.
.DEFAULT_GOAL := help
COMPOSE := docker compose

.PHONY: help up down restart logs ps config smoke wipe backup

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | sort

up: ## Build + start the stack
	$(COMPOSE) up -d --build

down: ## Stop the stack (keeps the DB volume)
	$(COMPOSE) down

restart: ## Rebuild + restart
	$(COMPOSE) up -d --build

logs: ## Follow Hindsight logs
	$(COMPOSE) logs -f hindsight

ps: ## Show service status
	$(COMPOSE) ps

config: ## Validate the merged compose config
	$(COMPOSE) config >/dev/null && echo "compose config OK"

smoke: ## Run the end-to-end validation
	./scripts/smoke.sh

# WARNING: -v drops the DB volume. Required before re-init, since Hindsight fixes the
# embedding dimension + vector extension at schema-creation time and cannot change them in place.
wipe: ## Stop AND delete the DB volume (fresh start)
	$(COMPOSE) down -v

backup: ## Dump the Hindsight DB to hindsight-<date>.sql.gz
	$(COMPOSE) exec -T hindsight-db pg_dump -U hindsight hindsight | gzip > hindsight-$$(date +%F).sql.gz
