SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CHART := $(ROOT)/helm/audit-loki
PYTHON ?= python3

.PHONY: help deploy destroy test test-attribution enable-console-plugin \
	helm-lint helm-template secret lint

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nDeploy requires AZURE_STORAGE_ACCOUNT_NAME and AZURE_STORAGE_ACCOUNT_KEY.\n\n"

deploy: ## Install operators, LokiStack, audit forwarder, and console plugin
	"$(ROOT)/scripts/deploy.sh"

destroy: ## Remove the forwarder, LokiStack, and collector RBAC (asks for confirmation)
	"$(ROOT)/scripts/destroy.sh"

test: ## Run local validation (pytest, yamllint, shell syntax, helm lint)
	$(PYTHON) -m pytest tests/ -v --tb=short --junitxml="$(ROOT)/test-results.xml"
	@if command -v yamllint >/dev/null 2>&1; then \
		yamllint -c "$(ROOT)/.yamllint.yaml" "$(ROOT)/manifests" "$(ROOT)/helm/audit-loki/Chart.yaml" "$(ROOT)/helm/audit-loki/values.yaml" "$(ROOT)/.onedev-buildspec.yml"; \
	else \
		echo "yamllint not on PATH; pytest still parsed the YAML"; \
	fi
	@bash -n "$(ROOT)/scripts/common.sh"
	@bash -n "$(ROOT)/scripts/deploy.sh"
	@bash -n "$(ROOT)/scripts/destroy.sh"
	@bash -n "$(ROOT)/scripts/test-attribution.sh"
	@bash -n "$(ROOT)/scripts/enable-console-plugin.sh"
	@if command -v helm >/dev/null 2>&1; then helm lint "$(CHART)"; else echo "helm not on PATH; skip helm lint"; fi

test-attribution: ## Create/delete a ConfigMap and print LogQL to verify user attribution
	"$(ROOT)/scripts/test-attribution.sh"

enable-console-plugin: ## Append logging-view-plugin without wiping other console plugins
	"$(ROOT)/scripts/enable-console-plugin.sh"

helm-lint: ## helm lint the audit-loki chart
	helm lint "$(CHART)"

helm-template: ## Render the chart with placeholder Azure values (no cluster required)
	helm template audit-loki "$(CHART)" \
		--set azure.accountName=exampleaccount \
		--set azure.accountKey=examplekey \
		--set azure.container=loki-audit

secret: ## Create/update the Azure Blob secret from environment variables
	@test -n "$${AZURE_STORAGE_ACCOUNT_NAME:-}" || (echo "AZURE_STORAGE_ACCOUNT_NAME is required" >&2; exit 1)
	@test -n "$${AZURE_STORAGE_ACCOUNT_KEY:-}" || (echo "AZURE_STORAGE_ACCOUNT_KEY is required" >&2; exit 1)
	oc create secret generic logging-loki-azure \
		--namespace openshift-logging \
		--from-literal=environment="$${AZURE_ENVIRONMENT:-AzureGlobal}" \
		--from-literal=account_name="$${AZURE_STORAGE_ACCOUNT_NAME}" \
		--from-literal=account_key="$${AZURE_STORAGE_ACCOUNT_KEY}" \
		--from-literal=container="$${AZURE_CONTAINER_NAME:-loki-audit}" \
		--dry-run=client -o yaml | oc apply -f -

lint: test ## Alias for test
