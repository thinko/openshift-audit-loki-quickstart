SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CHART := $(ROOT)/helm/audit-loki
PYTHON ?= python3

.PHONY: help deploy deploy-operators destroy test test-attribution enable-console-plugin \
	helm-lint helm-template secret azure-storage status preflight apply-rbac check-egress \
	deploy-dashboard deploy-grafana destroy-grafana lint

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nBlob storage can wait: make deploy-operators. Full deploy needs Azure Blob (docs/azure-blob-request.md).\n\n"

deploy: ## Install operators, LokiStack, audit forwarder, and console plugin
	"$(ROOT)/scripts/deploy.sh"

deploy-operators: ## Install Loki + logging operators only (no Blob secret / LokiStack)
	"$(ROOT)/scripts/deploy.sh" --operators-only

status: ## Show operator, secret-key, and LokiStack progress (does not print Azure keys)
	"$(ROOT)/scripts/status.sh"

preflight: ## Validate cluster readiness without changing anything (read-only)
	"$(ROOT)/scripts/preflight.sh"

apply-rbac: ## Pre-apply collector ServiceAccount and ClusterRoleBindings only
	"$(ROOT)/scripts/apply-rbac.sh"

check-egress: ## Test network egress from openshift-logging to Azure Blob (runs a probe pod)
	"$(ROOT)/scripts/check-egress.sh"

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
	@bash -n "$(ROOT)/scripts/create-azure-storage.sh"
	@bash -n "$(ROOT)/scripts/status.sh"
	@bash -n "$(ROOT)/scripts/preflight.sh"
	@bash -n "$(ROOT)/scripts/apply-rbac.sh"
	@bash -n "$(ROOT)/scripts/check-egress.sh"
	@bash -n "$(ROOT)/scripts/deploy-grafana.sh"
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

azure-storage: ## Create a dedicated Azure Blob account and container (AZURE_RESOURCE_GROUP required)
	"$(ROOT)/scripts/create-azure-storage.sh"

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

deploy-grafana: ## Deploy Grafana Operator, instance, datasources, and dashboards
	"$(ROOT)/scripts/deploy-grafana.sh"

destroy-grafana: ## Remove Grafana instance and CRs (leaves operator installed)
	@echo "==> Removing Grafana dashboards, datasources, and instance..."
	-oc delete grafanadashboard --all -n openshift-logging 2>/dev/null
	-oc delete grafanadatasource --all -n openshift-logging 2>/dev/null
	-oc delete grafana loki-grafana -n openshift-logging 2>/dev/null
	-oc delete secret grafana-prometheus-token grafana-loki-gateway-token -n openshift-logging 2>/dev/null
	-oc delete clusterrolebinding grafana-prometheus-monitoring-view grafana-loki-tenant-view 2>/dev/null
	-oc delete clusterrole grafana-loki-tenant-view 2>/dev/null
	-oc delete sa grafana-prometheus grafana-loki -n openshift-logging 2>/dev/null
	@echo "==> Grafana removed. Operator subscription left in place."
	@echo "    To fully remove: oc delete subscription grafana-operator -n openshift-operators"

deploy-dashboard: ## Deploy the Audit LokiStack Grafana dashboard to the Console
	@echo "==> Creating dashboard ConfigMap in openshift-config-managed..."
	oc create configmap audit-loki-dashboard \
		--from-file=audit-loki-overview.json="$(ROOT)/dashboards/audit-loki-overview.json" \
		-n openshift-config-managed \
		--dry-run=client -o yaml | oc apply -f -
	oc label configmap audit-loki-dashboard \
		console.openshift.io/dashboard=true \
		-n openshift-config-managed --overwrite
	@echo "==> Dashboard available at Observe > Dashboards > Audit LokiStack Overview"

lint: test ## Alias for test
