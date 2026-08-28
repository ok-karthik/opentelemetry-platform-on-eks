# ==============================================================================
# EKS OpenTelemetry Observability Platform Demo Makefile
# ==============================================================================

# Variables
APPS_CLUSTER ?= apps-workload-cluster-1
OTEL_CLUSTER ?= observability-cluster
AWS_REGION ?= us-east-1
APPS_MANIFEST_DIR = apps-workload-cluster-1/k8s-manifests
OBS_MANIFEST_DIR = observability-platform/k8s-manifests
AWS_ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
DOCKERHUB_USER_NAME ?=

.PHONY: help k8s-create k8s-create-infra k8s-create-helm k8s-destroy k8s-context k8s-deploy-all k8s-deploy-otel k8s-deploy-apps k8s-undeploy-all k8s-dashboards grafana-password k8s-status helm-lint ecr-build-push docker-build-push

help: ## Show this help message
	@echo "Usage: make [target]"
	@echo ""
	@echo "AWS EKS Infrastructure (Terraform):"
	@echo "  k8s-create           Create EKS clusters + deploy Helm charts (two-stage, recommended)"
	@echo "  k8s-create-infra     Stage 1 only — EKS, VPC, IAM, S3 (no Helm). Safe to re-run."
	@echo "  k8s-create-helm      Stage 2 only — Helm charts only. Assumes EKS is already up."
	@echo "  k8s-destroy          Destroy all AWS resources via Terraform"
	@echo "  k8s-context          Update kubeconfig context for both EKS clusters"
	@echo ""
	@echo "Container Images (Docker Hub & ECR):"
	@echo "  docker-build-push    Build and push demo images to Docker Hub (DOCKERHUB_USER_NAME=...)"
	@echo "  ecr-build-push       Build and push demo images to Amazon ECR"
	@echo ""
	@echo "Deploying Observability (Multi-Cluster):"
	@echo "  k8s-deploy-all       Deploy both the Otel Gateway stack and the microservices stack"
	@echo "  k8s-deploy-otel      Apply dashboards, Gateway, and LB Services to the observability cluster"
	@echo "  k8s-deploy-apps      Apply DaemonSet, Instrumentation, and apps to the workload cluster"
	@echo "  k8s-undeploy-all     Remove manifests from both clusters"
	@echo ""
	@echo "Access & Verification:"
	@echo "  k8s-dashboards       Port-forward Grafana to http://localhost:3000"
	@echo "  grafana-password     Print the generated Grafana admin password"
	@echo "  k8s-status           Show pod status across both clusters"
	@echo "  helm-lint            Render the LGTM charts locally without applying"


# ==============================================================================
# AWS EKS Infrastructure
# ==============================================================================
#
# Stage 1 targets only concrete infra resources (VPC, EKS, IAM, S3).
# No helm_release resources are touched until Stage 2, avoiding the
# "Helm provider talks to a not-yet-healthy API server" race condition.
#
# Infra resource targets for BOTH clusters:
INFRA_TARGETS := \
  -target='module.apps_workload_cluster_1' \
  -target='module.observability_cluster.module.eks' \
  -target='module.observability_cluster.module.karpenter' \
  -target='module.observability_cluster.aws_vpc.main' \
  -target='module.observability_cluster.aws_subnet.public' \
  -target='module.observability_cluster.aws_subnet.private' \
  -target='module.observability_cluster.aws_internet_gateway.gw' \
  -target='module.observability_cluster.aws_eip.nat' \
  -target='module.observability_cluster.aws_nat_gateway.nat' \
  -target='module.observability_cluster.aws_route_table.public_rt_otel' \
  -target='module.observability_cluster.aws_route_table.private_rt_otel' \
  -target='module.observability_cluster.aws_route_table_association.public' \
  -target='module.observability_cluster.aws_route_table_association.private' \
  -target='module.observability_cluster.aws_route.private_nat_otel' \
  -target='module.observability_cluster.aws_s3_bucket.loki_data' \
  -target='module.observability_cluster.aws_s3_bucket.tempo_data' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_blocks' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_ruler' \
  -target='module.observability_cluster.aws_s3_bucket.mimir_alertmanager' \
  -target='module.observability_cluster.aws_iam_policy.grafana_stack_s3' \
  -target='module.observability_cluster.aws_iam_role.grafana_stack' \
  -target='module.observability_cluster.aws_iam_role_policy_attachment.grafana_stack_s3_attach' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.loki' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.tempo' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.mimir' \
  -target='module.observability_cluster.aws_iam_policy.aws_lb_controller' \
  -target='module.observability_cluster.aws_iam_role.aws_lb_controller' \
  -target='module.observability_cluster.aws_iam_role_policy_attachment.aws_lb_controller' \
  -target='module.observability_cluster.aws_eks_pod_identity_association.aws_lb_controller' \
  -target='aws_vpc_peering_connection.peering' \
  -target='aws_route.apps_to_otel' \
  -target='aws_route.otel_to_apps'

k8s-create: ## Create both EKS clusters and deploy all Helm charts (two-stage)
	@echo "=== Stage 1: Provisioning EKS clusters, VPC, IAM, S3 (no Helm) ==="
	cd terraform && terraform init -upgrade && \
	  terraform apply $(INFRA_TARGETS) \
	    -parallelism=20 \
	    -auto-approve
	@echo ""
	@echo "=== Stage 2: Installing Helm charts (cert-manager, OTel, LGTM, Karpenter) ==="
	cd terraform && \
	  terraform apply \
	    -var="deploy_observability_stack=true" \
	    -parallelism=20 \
	    -auto-approve

k8s-create-infra: ## Stage 1 only — provision EKS infra without Helm charts (for re-runs)
	@echo "=== Stage 1 only: EKS infra ==="
	cd terraform && terraform init -upgrade && \
	  terraform apply $(INFRA_TARGETS) \
	    -parallelism=20 \
	    -auto-approve

k8s-create-helm: ## Stage 2 only — install/upgrade Helm charts (assumes EKS is already up)
	@echo "=== Stage 2 only: Helm charts ==="
	cd terraform && \
	  terraform apply \
	    -var="deploy_observability_stack=true" \
	    -parallelism=20 \
	    -auto-approve

k8s-destroy: ## Destroy all AWS resources
	cd terraform && terraform destroy \
	  -var="deploy_observability_stack=true" \
	  -parallelism=20 \
	  -auto-approve

k8s-context:
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(APPS_CLUSTER) --alias $(APPS_CLUSTER)
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(OTEL_CLUSTER) --alias $(OTEL_CLUSTER)

# ==============================================================================
# EKS Production Deployment Targets
# ==============================================================================
k8s-deploy-all: k8s-context k8s-deploy-otel k8s-deploy-apps ## Deploy everything to EKS in order

k8s-deploy-otel:
	@echo "Waiting for Cert-Manager in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(OTEL_CLUSTER) apply -f -
	@echo "Waiting for Grafana in $(OTEL_CLUSTER)..."
	@echo "  (Loki/Tempo/Mimir/Grafana are installed by Terraform — run 'make k8s-create-helm' if this times out)"
	kubectl --context $(OTEL_CLUSTER) wait --for=condition=Available --timeout=600s deployment/grafana -n monitoring
	@echo "Applying golden-signals dashboards in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/grafana-dashboards-configmap.yaml
	@echo "Applying Mimir Ruler SLO alert rules in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/mimir-ruler-rules-configmap.yaml
	@echo "Applying Alert Sink in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/alert-sink.yaml
	@echo "Applying GoAlert in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/goalert.yaml
	@echo "Applying Ingress for Grafana in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/grafana-ingress.yaml
	@echo "Applying Gateway in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/otel-collector-gateway.yaml
	@echo "Exposing Gateway via AWS NLB in $(OTEL_CLUSTER)..."
	kubectl --context $(OTEL_CLUSTER) apply -f $(OBS_MANIFEST_DIR)/svc-nlb-otel-gateway.yaml

docker-build-push: ## Build and push Go and Python app images to Docker Hub (make docker-build-push DOCKERHUB_USER_NAME=youruser)
	@echo "Logging into Docker Hub..."
	@if [ -z "$(DOCKERHUB_USER_NAME)" ]; then \
		echo "ERROR: Please provide DOCKERHUB_USER_NAME (e.g., make docker-build-push DOCKERHUB_USER_NAME=youruser)"; \
		exit 1; \
	fi; \
	docker login -u $(DOCKERHUB_USER_NAME)
	@echo "Building and pushing Go Product Service..."
	docker build -t $(DOCKERHUB_USER_NAME)/golang-product-service:latest apps-workload-cluster-1/apps-src/golang-app
	docker push $(DOCKERHUB_USER_NAME)/golang-product-service:latest
	@echo "Building and pushing Python Product Info Service..."
	docker build -t $(DOCKERHUB_USER_NAME)/python-product-info-service:latest apps-workload-cluster-1/apps-src/python-app
	docker push $(DOCKERHUB_USER_NAME)/python-product-info-service:latest
	@echo "Successfully pushed images to Docker Hub."

ecr-build-push: ## Build and push Go + Python app container images to Amazon ECR
	@echo "Logging into Amazon ECR in $(AWS_REGION)..."
	$(eval ACCOUNT_ID := $(if $(AWS_ACCOUNT_ID),$(AWS_ACCOUNT_ID),$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)))
	@if [ -z "$(ACCOUNT_ID)" ]; then \
		echo "ERROR: Could not retrieve AWS Account ID. Please authenticate with AWS first."; \
		exit 1; \
	fi; \
	aws ecr get-login-password --region $(AWS_REGION) | docker login --username AWS --password-stdin $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
	@echo "Building and pushing Go Product Service..."
	docker build -t $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/golang-product-service:latest apps-workload-cluster-1/apps-src/golang-app
	docker push $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/golang-product-service:latest
	@echo "Building and pushing Python Product Info Service..."
	docker build -t $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/python-product-info-service:latest apps-workload-cluster-1/apps-src/python-app
	docker push $(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com/python-product-info-service:latest
	@echo "Successfully pushed images to ECR."

k8s-deploy-apps:
	@echo "Waiting for Cert-Manager in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
	@echo "Waiting for OTel Operator in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) wait --for=condition=Available --timeout=300s deployment/opentelemetry-operator -n opentelemetry-operator-system
	@echo "Applying Namespace in $(APPS_CLUSTER)..."
	kubectl --context $(APPS_CLUSTER) create namespace monitoring --dry-run=client -o yaml | kubectl --context $(APPS_CLUSTER) apply -f -
	@echo "Checking AWS Account ID..."
	$(eval ACCOUNT_ID := $(if $(AWS_ACCOUNT_ID),$(AWS_ACCOUNT_ID),$(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)))
	@if [ -z "$(ACCOUNT_ID)" ]; then \
		echo "ERROR: Could not retrieve AWS Account ID. Please authenticate with AWS first."; \
		exit 1; \
	fi; \
	echo "Using AWS Account ID: $(ACCOUNT_ID)"; \
	$(eval DOCKER_USER := $(strip $(DOCKERHUB_USER_NAME)))
	$(eval REGISTRY := $(if $(DOCKER_USER),$(DOCKER_USER),$(ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com))
	@echo "Using Image Registry / Prefix: $(REGISTRY)"; \
	echo "Waiting for OTel Gateway LoadBalancer hostname to be assigned..."; \
	for i in $$(seq 1 30); do \
		host=$$(kubectl --context $(OTEL_CLUSTER) get svc svc-nlb-otel-gateway -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
		if [ -n "$$host" ]; then \
			echo "Found OTel Gateway LoadBalancer Host: $$host"; \
			OTEL_GATEWAY_LB_HOST=$$host; \
			break; \
		fi; \
		echo "Waiting for LoadBalancer host allocation (attempt $$i/30)..."; \
		sleep 10; \
	done; \
	if [ -z "$$OTEL_GATEWAY_LB_HOST" ]; then \
		echo "ERROR: Timed out waiting for OTel Gateway LoadBalancer hostname."; \
		exit 1; \
	fi; \
	mkdir -p .tmp-manifests; \
	cp -R $(APPS_MANIFEST_DIR)/* .tmp-manifests/; \
	find .tmp-manifests -type f \( -name "*.yaml" -o -name "*.yml" \) | while read -r file; do \
		sed "s|<IMAGE_REGISTRY>|$(REGISTRY)|g" "$$file" > "$$file.tmp"; \
		sed "s|<AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com|$(REGISTRY)|g" "$$file.tmp" > "$$file"; \
		sed "s|<AWS_ACCOUNT_ID>|$(ACCOUNT_ID)|g" "$$file" > "$$file.tmp"; \
		sed "s|<OTEL_GATEWAY_LB_HOST>|$$OTEL_GATEWAY_LB_HOST|g" "$$file.tmp" > "$$file"; \
		rm -f "$$file.tmp"; \
	done; \
	echo "Applying rendered OTel Agent, Apps & Ingress in $(APPS_CLUSTER)..."; \
	kubectl --context $(APPS_CLUSTER) apply -R -f .tmp-manifests/; \
	rm -rf .tmp-manifests

# -R is required: the workload manifests live in per-app subdirectories, and a
# non-recursive delete silently skips everything under golang-app/ and
# python-app/, leaving the Deployments and the ALB behind.
k8s-undeploy-all:
	kubectl --context $(APPS_CLUSTER) delete -R -f $(APPS_MANIFEST_DIR)/ --ignore-not-found=true
	kubectl --context $(OTEL_CLUSTER) delete -R -f $(OBS_MANIFEST_DIR)/ --ignore-not-found=true

# ==============================================================================
# Access & Verification
# ==============================================================================

# The all-in-one `lgtm` chart exposed a single service on :3000. With the
# individual charts, Grafana is its own release and its Service listens on :80.
k8s-dashboards: ## Port-forward Grafana to http://localhost:3000
	@echo "Forwarding Grafana UI to http://localhost:3000 (from EKS $(OTEL_CLUSTER))..."
	@echo "Username: admin    Password: run 'make grafana-password'"
	@kubectl --context $(OTEL_CLUSTER) port-forward -n monitoring svc/grafana 3000:80

grafana-password: ## Print the chart-generated Grafana admin password
	@kubectl --context $(OTEL_CLUSTER) get secret grafana -n monitoring \
	  -o jsonpath='{.data.admin-password}' | base64 -d; echo

k8s-status: ## Show pod status on both clusters
	@echo "=== $(OTEL_CLUSTER) / monitoring ==="
	@kubectl --context $(OTEL_CLUSTER) get pods -n monitoring -o wide || true
	@echo ""
	@echo "=== $(OTEL_CLUSTER) / pending or unhealthy pods (all namespaces) ==="
	@kubectl --context $(OTEL_CLUSTER) get pods -A \
	  --field-selector=status.phase!=Running,status.phase!=Succeeded || true
	@echo ""
	@echo "=== $(APPS_CLUSTER) ==="
	@kubectl --context $(APPS_CLUSTER) get pods -A -o wide | grep -E 'monitoring|default|NAMESPACE' || true

# Renders the pinned charts with the repo's values so value-path mistakes are
# caught before a 15-minute apply. Helm ignores unknown keys silently, so a
# typo'd path produces a chart default rather than an error — diff the output
# when changing anything under terraform/observability-cluster/helm-values/.
helm-lint: ## Render LGTM + ELK charts locally (no cluster required)
	@helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
	@helm repo add opensearch https://opensearch-project.github.io/helm-charts/ >/dev/null 2>&1 || true
	@helm repo add elastic https://helm.elastic.co >/dev/null 2>&1 || true
	@helm repo update grafana opensearch elastic >/dev/null 2>&1 || true
	@mkdir -p .helm-render
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/loki.yaml.tftpl > .helm-render/loki.yaml
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/tempo.yaml.tftpl > .helm-render/tempo.yaml
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/mimir.yaml.tftpl > .helm-render/mimir.yaml
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/opensearch.yaml.tftpl > .helm-render/opensearch.yaml
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/opensearch-dashboards.yaml.tftpl > .helm-render/opensearch-dashboards.yaml
	@sed 's/$${\([a-z_]*\)}/PLACEHOLDER/g' \
	  terraform/observability-cluster/helm-values/logstash.yaml.tftpl > .helm-render/logstash.yaml
	@echo "--- loki 7.2.0 ---"
	@helm template loki grafana/loki --version 7.2.0 -n monitoring \
	  -f .helm-render/loki.yaml | grep -E '^kind:|^  name:' | paste - - | grep -E 'Deployment|StatefulSet|DaemonSet'
	@echo "--- tempo 1.24.4 ---"
	@helm template tempo grafana/tempo --version 1.24.4 -n monitoring \
	  -f .helm-render/tempo.yaml 2>/dev/null | grep -A3 'trace:' | head -8
	@echo "--- mimir-distributed 6.1.0 ---"
	@helm template mimir grafana/mimir-distributed --version 6.1.0 -n monitoring \
	  -f .helm-render/mimir.yaml | grep -E '^kind:|^  name:' | paste - - | grep -E 'Deployment|StatefulSet'
	@echo "--- opensearch 3.8.0 ---"
	@helm template opensearch opensearch/opensearch --version 3.8.0 -n monitoring \
	  -f .helm-render/opensearch.yaml | grep -E '^kind:|^  name:' | paste - - | grep -E 'StatefulSet'
	@echo "--- opensearch-dashboards 3.8.0 ---"
	@helm template opensearch-dashboards opensearch/opensearch-dashboards --version 3.8.0 -n monitoring \
	  -f .helm-render/opensearch-dashboards.yaml | grep -E '^kind:|^  name:' | paste - - | grep -E 'Deployment'
	@echo "--- logstash 8.5.1 ---"
	@helm template logstash elastic/logstash --version 8.5.1 -n monitoring \
	  -f .helm-render/logstash.yaml | grep -E '^kind:|^  name:' | paste - - | grep -E 'StatefulSet'
	@rm -rf .helm-render
