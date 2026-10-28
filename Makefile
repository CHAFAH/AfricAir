# AfricAir infrastructure and deployment (Projects 4 and 5).
#   make tf-plan | tf-apply | kubeconfig | cluster-secret-stores | helm-install | destroy
# Variables: ENV_DIR (Terraform root), NS (namespace), RELEASE, VALUES (extra values file), TAG (image tag)

SHELL        := /usr/bin/env bash -o pipefail -e
ENV_DIR      ?= infra/terraform/envs/staging
TF           ?= terraform
NS           ?= africair-staging
RELEASE      ?= africair
CHART        := deploy/helm/africair
VALUES       ?= $(CHART)/values-staging.local.yaml
TAG          ?= $(shell git rev-parse HEAD)

.PHONY: help tf-init tf-plan tf-apply kubeconfig cluster-secret-stores helm-lint helm-install destroy

help:
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-22s %s\n", $$1, $$2}'

tf-init: ## terraform init with the S3 backend (backend.hcl next to the root module)
	$(TF) -chdir=$(ENV_DIR) init -backend-config=backend.hcl

tf-plan: tf-init ## fmt, validate, tflint, trivy, then plan (writes $(ENV_DIR)/tfplan)
	$(TF) fmt -check -recursive infra/terraform
	$(TF) -chdir=$(ENV_DIR) validate
	tflint --config "$(CURDIR)/infra/terraform/.tflint.hcl" --recursive --chdir infra/terraform
	trivy config --severity HIGH,CRITICAL --exit-code 1 infra/terraform
	$(TF) -chdir=$(ENV_DIR) plan -out=tfplan

# Two phases on the first run: the Kubernetes/Helm providers need the cluster to exist before they can plan
# anything inside it. Later runs: the second command alone.
tf-apply: tf-init ## apply (network, EKS, RDS first; then the platform module)
	$(TF) -chdir=$(ENV_DIR) apply -target=module.network -target=module.eks -target=module.database
	$(TF) -chdir=$(ENV_DIR) apply

kubeconfig: ## point kubectl at the cluster
	$$($(TF) -chdir=$(ENV_DIR) output -raw kubeconfig_command)

cluster-secret-stores: kubeconfig ## ClusterSecretStores (Project 4; Argo CD owns them in Project 5)
	kubectl apply -f deploy/k8s/cluster-secret-stores.yaml
	kubectl wait --for=condition=Ready clustersecretstore/aws-secrets-manager clustersecretstore/aws-parameter-store --timeout=60s

helm-lint: ## helm lint + kubeconform on the rendered chart
	helm lint $(CHART) -f $(CHART)/values-staging.yaml
	helm template $(RELEASE) $(CHART) -n $(NS) -f $(CHART)/values-staging.yaml | \
	  kubeconform -strict -summary -schema-location default \
	    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

helm-install: kubeconfig ## install/upgrade the app (VALUES holds registry, secret ARN, bucket, host)
	kubectl create namespace $(NS) --dry-run=client -o yaml | kubectl apply -f -
	# The Load Balancer Controller injects readiness gates: a rollout waits until the ALB sees new pods healthy.
	kubectl label namespace $(NS) elbv2.k8s.aws/pod-readiness-gate-inject=enabled --overwrite
	helm upgrade --install $(RELEASE) $(CHART) -n $(NS) \
	  -f $(CHART)/values-staging.yaml $(if $(wildcard $(VALUES)),-f $(VALUES)) \
	  --set image.tag=$(TAG) --wait --timeout 10m
	kubectl -n $(NS) get externalsecret,deploy,ing

# Controllers create AWS resources Terraform doesn't know about (the ALB, its security groups and target
# groups; EBS volumes for PVCs). Delete them through Kubernetes first, or the VPC can't be destroyed
# (DependencyViolation on subnets and security groups).
destroy: kubeconfig ## delete Ingresses/PVCs, wait for the ALB to disappear, then terraform destroy
	-kubectl -n argocd delete application root --cascade=foreground --timeout=10m 2>/dev/null
	-kubectl delete ingress --all -A --timeout=5m
	-kubectl delete pvc --all -A --timeout=5m
	@vpc=$$($(TF) -chdir=$(ENV_DIR) output -raw vpc_id); \
	for i in $$(seq 60); do \
	  n=$$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='$$vpc'])" --output text); \
	  [ "$$n" = 0 ] && break; echo "waiting for $$n load balancer(s) in $$vpc to be deleted..."; sleep 10; \
	done
	$(TF) -chdir=$(ENV_DIR) destroy
	@echo "check: aws elbv2 describe-load-balancers, aws ec2 describe-nat-gateways --filter Name=state,Values=available, aws rds describe-db-instances"
