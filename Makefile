# Cross-platform convenience verbs over `docker compose` (macOS / Linux).
# Windows users: use `./run.ps1 <verb>` (same verbs). Docker is the only
# requirement for these backend/console verbs; product web apps also need
# Flutter. These are thin wrappers — `docker compose ...` always works too.
#
#   make up         start redis + api + worker + agent (detached)
#   make down       stop and remove the stack
#   make logs       follow logs for all services
#   make ps         show service status
#   make build      (re)build the api/worker images
#   make console    start the client model-test page on http://127.0.0.1:8010
#   make console-down   stop the model-test page (volunteer data is kept)

COMPOSE ?= docker compose

.PHONY: up down logs ps build console console-down restart health

up:
	$(COMPOSE) up -d
	@echo "Stack starting. Check readiness: curl -s http://127.0.0.1:8000/health/ready"

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

ps:
	$(COMPOSE) ps

build:
	$(COMPOSE) build

restart: down up

health:
	@curl -s http://127.0.0.1:8000/health/ready || echo "API not reachable yet"

console:
	$(COMPOSE) --profile console up -d console
	@echo "Model-test page: http://127.0.0.1:8010"

console-down:
	$(COMPOSE) --profile console stop console
