.DEFAULT_GOAL := help
SHELL := /bin/bash

COMPOSE_DIR := compose
CERTS_DIR   := certs
SECRETS_DIR := secrets
CA_FILE     := $(CERTS_DIR)/ca.crt
RS_URI      := "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0&authSource=admin"

.PHONY: help up down stop start restart destroy ps logs status shell secrets certs clean-certs check preflight

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## --- Lifecycle ---

up: ## Start the cluster in the background
	cd $(COMPOSE_DIR) && docker compose up -d
	@sleep 2
	cd $(COMPOSE_DIR) && docker compose ps

down: ## Remove containers and network (volumes are kept)
	cd $(COMPOSE_DIR) && docker compose down

stop: ## Stop the containers, preserving state
	cd $(COMPOSE_DIR) && docker compose stop

start: ## Restart stopped containers
	cd $(COMPOSE_DIR) && docker compose start

restart: ## Restart the cluster
	cd $(COMPOSE_DIR) && docker compose restart

destroy: ## DESTRUCTIVE: also removes volumes and all data
	@read -p "This will delete all data. Continue? [y/N] " ok; \
	 [[ $$ok == "y" ]] && cd $(COMPOSE_DIR) && docker compose down -v || echo "Cancelled."

## --- Inspection ---

ps: ## Container status, including stopped ones
	cd $(COMPOSE_DIR) && docker compose ps -a

logs: ## Follow logs (make logs NODE=mongo2)
	cd $(COMPOSE_DIR) && docker compose logs -f $(or $(NODE),mongo1)

status: ## Replica set status
	@mongosh $(RS_URI) --tls --tlsCAFile $(CA_FILE) \
		--username admin --authenticationDatabase admin \
		--quiet --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'

shell: ## Open mongosh against the replica set
	@mongosh $(RS_URI) --tls --tlsCAFile $(CA_FILE) \
		--username admin --authenticationDatabase admin

## --- Secret generation ---

secrets: ## Generate the internal authentication keyfile
	@mkdir -p $(SECRETS_DIR)
	@test -f $(SECRETS_DIR)/keyfile && echo "Keyfile already exists." || ( \
		openssl rand -base64 756 > $(SECRETS_DIR)/keyfile && \
		chmod 400 $(SECRETS_DIR)/keyfile && \
		sudo chown 999:999 $(SECRETS_DIR)/keyfile && \
		echo "Keyfile generated." )

certs: ## Generate the CA and per-node certificates
	@mkdir -p $(CERTS_DIR)
	@test -f $(CERTS_DIR)/ca.key && echo "CA already exists. Run 'make clean-certs' first." || ( \
		cd $(CERTS_DIR) && \
		openssl genrsa -out ca.key 4096 2>/dev/null && \
		openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
			-subj "/C=ES/O=mongo-ha-lab/CN=mongo-ha-lab-CA" && \
		for n in mongo1 mongo2 mongo3; do \
			openssl genrsa -out $$n.key 2048 2>/dev/null; \
			openssl req -new -key $$n.key -out $$n.csr -subj "/C=ES/O=mongo-ha-lab/CN=$$n"; \
			openssl x509 -req -in $$n.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
				-out $$n.crt -days 825 \
				-extfile <(printf "subjectAltName=DNS:$$n,DNS:localhost,IP:127.0.0.1") 2>/dev/null; \
			cat $$n.key $$n.crt > $$n.pem; \
		done && \
		rm -f *.csr && chmod 400 *.key *.pem && chmod 444 *.crt && \
		sudo chown 999:999 *.pem ca.crt && \
		echo "Certificates generated." )

clean-certs: ## Remove the CA and all certificates
	@read -p "Remove all certificates? [y/N] " ok; \
	 [[ $$ok == "y" ]] && sudo rm -rf $(CERTS_DIR) && echo "Removed." || echo "Cancelled."

## --- Verification ---

preflight: ## Check environment preconditions
	@echo "--- Docker ---"
	@systemctl is-active docker || echo "Docker is not running"
	@echo "--- Disk space ---"
	@df -h / | tail -1
	@echo "--- Name resolution ---"
	@getent hosts mongo1 mongo2 mongo3 || echo "Missing /etc/hosts entries"
	@echo "--- Required files ---"
	@test -f .env && echo ".env present" || echo ".env MISSING"
	@test -f $(SECRETS_DIR)/keyfile && echo "keyfile present" || echo "keyfile MISSING"
	@test -f $(CA_FILE) && echo "CA present" || echo "CA MISSING"

check: ## Verify no secrets are tracked in version control
	@echo "--- Ignored files ---"
	@git status --ignored --short | grep -E "\.env|secrets|certs" || echo "(none)"
	@echo "--- Credential search across tracked files ---"
	@git grep -n "PASS=" -- ':!.env.example' || echo "No matches outside .env.example"
	@echo "--- Hooks ---"
	@pre-commit run --all-files
