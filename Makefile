SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

export SANDBOX_ROOT ?= $(CURDIR)

.PHONY: help quickstart init up down create destroy logs health simulate clean

help:
	@echo "Targets: quickstart init up down create destroy logs health simulate clean"

quickstart: init up

init:
	@test -f .env || cp .env.example .env
	@python3 platform/patch_env_root.py "$(CURDIR)"
	@chmod +x platform/*.sh 2>/dev/null || true

up: init
	docker compose up -d --build
	@mkdir -p logs envs
	@if [ -f .cleanup.pid ] && kill -0 "$$(cat .cleanup.pid)" 2>/dev/null; then \
		echo "cleanup daemon already running (pid $$(cat .cleanup.pid))"; \
	else \
		SANDBOX_ROOT=$(CURDIR) nohup bash platform/cleanup_daemon.sh >> logs/cleanup_stdout.log 2>&1 & echo $$! > .cleanup.pid; \
		echo "cleanup daemon pid $$(cat .cleanup.pid)"; \
	fi
	@if [ -f .health_poller.pid ] && kill -0 "$$(cat .health_poller.pid)" 2>/dev/null; then \
		echo "health poller already running (pid $$(cat .health_poller.pid))"; \
	else \
		SANDBOX_ROOT=$(CURDIR) nohup python3 monitor/health_poller.py >> logs/health_poller_stdout.log 2>&1 & echo $$! > .health_poller.pid; \
		echo "health poller pid $$(cat .health_poller.pid)"; \
	fi
	@echo "Control API docs: http://127.0.0.1:9090/docs"
	@echo "Edge Nginx:       http://127.0.0.1:80/"

down:
	-@if [ -f .cleanup.pid ]; then kill "$$(cat .cleanup.pid)" 2>/dev/null || true; rm -f .cleanup.pid; fi
	-@if [ -f .health_poller.pid ]; then kill "$$(cat .health_poller.pid)" 2>/dev/null || true; rm -f .health_poller.pid; fi
	-@shopt -s nullglob; \
		for f in envs/*.json; do \
			[ -f "$$f" ] || continue; \
			id="$$(basename "$$f" .json)"; \
			SANDBOX_ROOT=$(CURDIR) bash platform/destroy_env.sh "$$id" || true; \
		done; \
		shopt -u nullglob
	docker compose down

create:
	@read -p "Environment name: " name; \
		read -p "TTL seconds [1800]: " ttl; \
		ttl=$${ttl:-1800}; \
		SANDBOX_ROOT=$(CURDIR) bash platform/create_env.sh "$$name" "$$ttl"

destroy:
	@test -n "$(ENV)" || (echo "Usage: make destroy ENV=env-..." >&2 && exit 1)
	SANDBOX_ROOT=$(CURDIR) bash platform/destroy_env.sh "$(ENV)"

logs:
	@test -n "$(ENV)" || (echo "Usage: make logs ENV=env-..." >&2 && exit 1)
	@if [ -f "$(CURDIR)/logs/$(ENV)/app.log" ]; then \
		tail -n 100 -f "$(CURDIR)/logs/$(ENV)/app.log"; \
	elif [ -f "$(CURDIR)/logs/archived/$(ENV)/app.log" ]; then \
		echo "[archived]"; \
		tail -n 100 "$(CURDIR)/logs/archived/$(ENV)/app.log"; \
	else \
		echo "No log file found for $(ENV)" >&2; exit 1; \
	fi

health:
	@python3 platform/show_health.py "$(CURDIR)"

simulate:
	@test -n "$(ENV)" || (echo "Usage: make simulate ENV=env-... MODE=crash|pause|network|recover|stress" >&2 && exit 1)
	@test -n "$(MODE)" || (echo "Usage: make simulate ENV=env-... MODE=..." >&2 && exit 1)
	SANDBOX_ROOT=$(CURDIR) bash platform/simulate_outage.sh --env "$(ENV)" --mode "$(MODE)"

clean: down
	rm -rf logs/* envs/.sim
	rm -f envs/*.json .cleanup.pid .health_poller.pid
	@find nginx/conf.d -maxdepth 1 -type f -name 'env-*.conf' ! -name 'env-bootstrap.conf' -delete 2>/dev/null || true
	@mkdir -p logs envs nginx/conf.d
