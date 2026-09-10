SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
CHART := $(ROOT)/helm/audit-loki
PYTHON ?= python3

# Environment overrides: copy .env.example → .env and fill in values.
# .env is gitignored. Loaded automatically via _load_env (shell source).
define _load_env
if [ -f "$(ROOT)/.env" ]; then set -a; . "$(ROOT)/.env"; set +a; fi
endef

.PHONY: help deploy deploy-operators destroy test test-attribution enable-console-plugin \
	helm-lint helm-template secret azure-storage status preflight apply-rbac check-egress \
	deploy-grafana destroy-grafana deploy-console-dashboards deploy-alerting lint \
	add-storage-subnet init-sp-auth generate-dashboard-configmap

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\nBlob storage can wait: make deploy-operators. Full deploy needs Azure Blob (docs/azure-blob-request.md).\n\n"

deploy: ## Install operators, LokiStack, audit forwarder, and console plugin
	$(_load_env); "$(ROOT)/scripts/deploy.sh"

deploy-operators: ## Install Loki + logging operators only (no Blob secret / LokiStack)
	$(_load_env); "$(ROOT)/scripts/deploy.sh" --operators-only

status: ## Show operator, secret-key, and LokiStack progress (does not print Azure keys)
	$(_load_env); "$(ROOT)/scripts/status.sh"

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
		yamllint -c "$(ROOT)/.yamllint.yaml" "$(ROOT)/manifests" "$(ROOT)/helm/audit-loki/Chart.yaml" "$(ROOT)/helm/audit-loki/values.yaml" "$(ROOT)/gitops/namespaces/openshift-logging" "$(ROOT)/.onedev-buildspec.yml"; \
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
	@bash -n "$(ROOT)/scripts/init-sp-auth.sh"
	@bash -n "$(ROOT)/scripts/add-storage-subnet.sh"
	@bash -n "$(ROOT)/scripts/sync-gitops-to-internal.sh"
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
	$(_load_env); "$(ROOT)/scripts/apply-azure-secret.sh"

deploy-grafana: ## Deploy standalone Grafana with datasources and dashboards
	$(_load_env); "$(ROOT)/scripts/deploy-grafana.sh"

destroy-grafana: ## Remove standalone Grafana deployment and associated resources
	@echo "==> Removing Grafana deployment, service, route, and ConfigMaps..."
	-oc delete route loki-grafana -n openshift-logging 2>/dev/null
	-oc delete service loki-grafana -n openshift-logging 2>/dev/null
	-oc delete deployment loki-grafana -n openshift-logging 2>/dev/null
	-oc delete configmap grafana-config grafana-datasource-provisioning \
		grafana-dashboard-provider grafana-dashboards \
		-n openshift-logging 2>/dev/null
	-oc delete secret grafana-admin-credentials -n openshift-logging 2>/dev/null
	-oc delete clusterrolebinding grafana-prometheus-monitoring-view grafana-loki-tenant-view 2>/dev/null
	-oc delete clusterrole grafana-loki-tenant-view 2>/dev/null
	-oc delete sa grafana-loki grafana-prometheus -n openshift-logging 2>/dev/null
	@echo "==> Grafana removed."

deploy-console-dashboards: ## Deploy Prometheus dashboards to OCP Console (Observe > Dashboards)
	oc apply -f "$(ROOT)/manifests/11-console-dashboards.yaml"
	@echo "==> Console dashboards deployed to Observe > Dashboards"

deploy-alerting: ## Deploy PrometheusRule and AlertmanagerConfig for LokiStack alerts
	oc apply -f "$(ROOT)/manifests/12-alerting.yaml"
	@echo "==> Alerting rules deployed. Verify: oc -n openshift-logging get prometheusrule,alertmanagerconfig"

add-storage-subnet: ## Add ARO worker subnet to Azure storage account network ACL
	$(_load_env); "$(ROOT)/scripts/add-storage-subnet.sh"

init-sp-auth: ## Bootstrap service principal auth for Loki (AllowSharedKeyAccess=false workaround)
	$(_load_env); "$(ROOT)/scripts/init-sp-auth.sh"

generate-dashboard-configmap: ## Regenerate gitops dashboards ConfigMap from dashboards/*.json
	@echo "#! Grafana dashboards ConfigMap — auto-generated from dashboards/*.json." \
		> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "#! Regenerate with: make generate-dashboard-configmap" \
		>> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "#!" >> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "#! Do not edit dashboard JSON here; edit the source files in dashboards/" \
		>> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "#! and re-run the generator." \
		>> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "---" >> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@oc create configmap grafana-dashboards -n openshift-logging \
		$$(for f in "$(ROOT)/dashboards"/grafana-*.json; do \
			echo "--from-file=$$(basename $$f)=$$f"; \
		done) \
		--dry-run=client -o yaml \
		| sed '/^metadata:/a\  labels:\n    app.kubernetes.io/name: loki-grafana\n    app.kubernetes.io/part-of: openshift-logging\n  annotations:\n    argocd.argoproj.io/sync-wave: "5"' \
		>> "$(ROOT)/gitops/namespaces/openshift-logging/grafana-dashboards.yaml"
	@echo "Generated: gitops/namespaces/openshift-logging/grafana-dashboards.yaml"

lint: test ## Alias for test
