.DEFAULT_GOAL := help
SHELL := /bin/bash

ANSIBLE_DIR := ansible
CERTS_DIR   := certs
SECRETS_DIR := secrets
CA_FILE     := $(CERTS_DIR)/ca.crt
KEYFILE     := $(SECRETS_DIR)/keyfile
NODES       := mongo1 mongo2 mongo3
VOLUMES     := mongo1_data mongo2_data mongo3_data
NETWORK     := mongo-net
PRIMARY_CMD := docker exec -it mongo1 mongosh --port 27017 \
                 --tls --tlsCAFile /etc/mongo/certs/ca.crt --tlsAllowInvalidHostnames \
                 --username admin --authenticationDatabase admin

.PHONY: help preflight keyfile up down stop start restart destroy ps logs status shell test check clean-certs

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

## --- Provisioning ---

keyfile: ## Create the replica set keyfile (requires root; see ADR 0005)
	@test -f $(KEYFILE) && echo "Keyfile already exists." || ( \
		mkdir -p $(SECRETS_DIR) && \
		openssl rand -base64 756 > $(KEYFILE) && \
		sudo chown 999:999 $(KEYFILE) && \
		sudo chmod 400 $(KEYFILE) && \
		echo "Keyfile created." )
	@ls -ln $(KEYFILE)

up: ## Provision the lab with Ansible
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml --ask-vault-pass
	@docker ps --filter "name=mongo" --format "table {{.Names}}\t{{.Status}}"

## --- Lifecycle ---

stop: ## Stop the containers, preserving state
	@docker stop $(NODES)

start: ## Start stopped containers
	@docker start $(NODES)
	@sleep 5
	@docker ps --filter "name=mongo" --format "table {{.Names}}\t{{.Status}}"

restart: ## Restart the containers
	@docker restart $(NODES)

down: ## Remove containers and network (volumes and certificates are kept)
	-@docker rm -f $(NODES)
	-@docker network rm $(NETWORK)

destroy: ## DESTRUCTIVE: remove containers, volumes, certificates and keyfile
	@read -p "This deletes all data, certificates and the keyfile. Continue? [y/N] " ok; \
	 if [[ $$ok == "y" ]]; then \
	   docker rm -f $(NODES) 2>/dev/null || true; \
	   docker volume rm $(VOLUMES) 2>/dev/null || true; \
	   docker network rm $(NETWORK) 2>/dev/null || true; \
	   rm -rf $(CERTS_DIR); \
	   sudo rm -f $(KEYFILE); \
	   echo "Lab destroyed."; \
	 else echo "Cancelled."; fi

## --- Inspection ---

ps: ## Container status, including stopped ones
	@docker ps -a --filter "name=mongo" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

logs: ## Follow a node's logs (make logs NODE=mongo2)
	@docker logs -f $(or $(NODE),mongo1)

status: ## Replica set member states
	@$(PRIMARY_CMD) --quiet \
		--eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'

users: ## List database users
	@$(PRIMARY_CMD) --quiet \
		--eval 'db.getSiblingDB("admin").system.users.find({}, {user:1, db:1, _id:0}).toArray()'

shell: ## Open a mongosh session as admin
	@$(PRIMARY_CMD)

## --- Validation ---

test: ## Run the test suite against the running lab
	@test -n "$$MONGO_ADMIN_PASS" || { echo "Export MONGO_ADMIN_PASS and MONGO_APP_PASS first."; exit 1; }
	python -m pytest tests/ -v

preflight: ## Check environment preconditions
	@echo "--- Docker ---"
	@systemctl is-active docker || echo "Docker is not running"
	@echo "--- Disk space ---"
	@df -h / | tail -1
	@echo "--- Name resolution ---"
	@getent hosts $(NODES) | sort -u || echo "Missing /etc/hosts entries"
	@echo "--- Required files ---"
	@test -f $(KEYFILE) && echo "keyfile present" || echo "keyfile MISSING (run: make keyfile)"
	@test -f $(CA_FILE) && echo "CA present" || echo "CA MISSING (run: make up)"
	@test -f $(ANSIBLE_DIR)/group_vars/all/vault.yml && echo "vault present" || echo "vault MISSING"

check: ## Verify no secrets are tracked in version control
	@echo "--- Ignored files ---"
	@git status --ignored --short | grep -E "\.env|secrets|certs|initdb" || echo "(none)"
	@echo "--- Vault is encrypted ---"
	@head -1 $(ANSIBLE_DIR)/group_vars/all/vault.yml | grep -q ANSIBLE_VAULT \
		&& echo "vault.yml is encrypted" || echo "WARNING: vault.yml is NOT encrypted"
	@echo "--- Hooks ---"
	@pre-commit run --all-files

## --- Maintenance ---

clean-certs: ## Remove certificates so the next run regenerates them
	@read -p "Remove all certificates? [y/N] " ok; \
	 [[ $$ok == "y" ]] && rm -rf $(CERTS_DIR) && echo "Removed." || echo "Cancelled."
