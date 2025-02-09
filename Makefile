APP_VERSION ?= $(shell git describe --abbrev=5 --dirty --tags --always)
REGISTRY := quay.io/presslabs
IMAGE_NAME := mysql-operator
ORCHESTRATOR_IMAGE_NAME := mysql-operator-orchestrator
SIDECAR_MYSQL57_IMAGE_NAME := mysql-operator-sidecar-mysql57
SIDECAR_MYSQL8_IMAGE_NAME := mysql-operator-sidecar-mysql8
BUILD_TAG := build
# strip prefix v from git tag
IMAGE_TAGS := $(APP_VERSION:v%=%)
PKG_NAME := github.com/presslabs/mysql-operator

BINDIR := $(PWD)/bin
KUBEBUILDER_VERSION ?= 2.3.1
HELM_VERSION ?= 3.2.4
GOLANGCI_LINTER_VERSION ?= 1.24.0
YQ_VERSION ?= 3.3.2

GOOS ?= $(shell uname -s | tr '[:upper:]' '[:lower:]')
GOARCH ?= amd64

PATH := $(BINDIR):$(PATH)
SHELL := env PATH=$(PATH) /bin/sh

# check if kubebuilder is installed in local bin dir and set KUBEBUILDER_ASSETS
ifneq ("$(wildcard $(BINDIR)/kubebuilder)", "")
	export KUBEBUILDER_ASSETS ?= $(BINDIR)
endif

all: test build

# Run tests
test: generate fmt vet manifests
	@# Disable --race until https://github.com/kubernetes-sigs/controller-runtime/issues/1171 is fixed.
	ginkgo --randomizeAllSpecs --randomizeSuites --failOnPending --flakeAttempts=2 \
			--cover --coverprofile cover.out --trace --progress  $(TEST_ARGS)\
			./pkg/... ./cmd/...

# Build mysql-operator binary
build: generate fmt vet
	go build -o bin/mysql-operator github.com/presslabs/mysql-operator/cmd/mysql-operator
	go build -o bin/mysql-operator-sidecar github.com/presslabs/mysql-operator/cmd/mysql-operator-sidecar
	go build -o bin/orc-helper github.com/presslabs/mysql-operator/cmd/orc-helper

# skaffold build
bin/mysql-operator_linux_amd64: $(shell hack/development/related-go-files.sh $(PKG_NAME) cmd/mysql-operator/main.go)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o bin/mysql-operator_linux_amd64 github.com/presslabs/mysql-operator/cmd/mysql-operator

bin/mysql-operator-sidecar_linux_amd64: $(shell hack/development/related-go-files.sh $(PKG_NAME) cmd/mysql-operator-sidecar/main.go)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o bin/mysql-operator-sidecar_linux_amd64 github.com/presslabs/mysql-operator/cmd/mysql-operator-sidecar

bin/orc-helper_linux_amd64: $(shell hack/development/related-go-files.sh $(PKG_NAME) cmd/orc-helper/main.go)
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o bin/orc-helper_linux_amd64 github.com/presslabs/mysql-operator/cmd/orc-helper

skaffold-build: bin/mysql-operator_linux_amd64 bin/mysql-operator-sidecar_linux_amd64 bin/orc-helper_linux_amd64

skaffold-run: skaffold-build
	skaffold run --cache-artifacts=true

# Run against the configured Kubernetes cluster in ~/.kube/config
run: generate fmt vet
	go run ./cmd/mysql-operator/main.go

# Install CRDs into a cluster
install: manifests
	kubectl apply -f config/crds

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests
	kubectl apply -f config/crds


MANIFESTS_DIR ?= config
CRD_DIR ?= $(MANIFESTS_DIR)/crds
RBAC_DIR ?= $(MANIFESTS_DIR)/rbac
BOILERPLATE_FILE ?= ./hack/boilerplate.go.txt

GEN_CRD_OPTIONS ?= crd:trivialVersions=true
GEN_RBAC_OPTIONS ?= rbac:roleName=manager-role
GEN_WEBHOOK_OPTIONS ?= webhook
GEN_OBJECT_OPTIONS ?= object:headerFile=$(BOILERPLATE_FILE)
GEN_OUTPUTS_OPTIONS ?= output:crd:artifacts:config=$(CRD_DIR) output:rbac:artifacts:config=$(RBAC_DIR)


# Generate manifests e.g. CRD, RBAC etc.
manifests: $(CONTROLLER_GEN)
	@rm -rf $(CRD_DIR)
	@rm -rf $(RBAC_DIR)

	$(BINDIR)/controller-gen paths="./pkg/..." $(GEN_CRD_OPTIONS) $(GEN_RBAC_OPTIONS) $(GEN_WEBHOOK_OPTIONS) $(GEN_OBJECT_OPTIONS) $(GEN_OUTPUTS_OPTIONS)

	cd hack && ./generate_chart_manifests.sh

# Run go fmt against code
fmt:
	go fmt ./pkg/... ./cmd/...

# Run go vet against code
vet:
	go vet ./pkg/... ./cmd/...

# Generate code
generate: manifests

lint:
	$(BINDIR)/golangci-lint run --timeout 2m0s ./pkg/... ./cmd/...
	hack/license-check

.PHONY: chart
chart: generate manifests
	cd hack && ./generate_chart.sh $(APP_VERSION)

dependencies:
	test -d $(BINDIR) || mkdir $(BINDIR)
	GOBIN=$(BINDIR) go install github.com/onsi/ginkgo/ginkgo@v1.16.4

	curl -sfL https://install.goreleaser.com/github.com/golangci/golangci-lint.sh | bash -s -- -b $(BINDIR) v$(GOLANGCI_LINTER_VERSION)

	GOBIN=$(BINDIR) go install sigs.k8s.io/controller-tools/cmd/controller-gen@v0.5.0

dependencies-local: dependencies
	curl -sL https://github.com/mikefarah/yq/releases/download/$(YQ_VERSION)/yq_$(GOOS)_$(GOARCH) -o $(BINDIR)/yq
	chmod +x $(BINDIR)/yq
	curl -sL https://github.com/kubernetes-sigs/kubebuilder/releases/download/v$(KUBEBUILDER_VERSION)/kubebuilder_$(KUBEBUILDER_VERSION)_$(GOOS)_$(GOARCH).tar.gz | \
				tar -zx -C $(BINDIR) --strip-components=2
	curl -sL https://get.helm.sh/helm-v$(HELM_VERSION)-$(GOOS)-$(GOARCH).tar.gz | \
		tar -C $(BINDIR) -xz --strip-components 1 $(GOOS)-$(GOARCH)/helm
	chmod +x $(BINDIR)/helm

# Build the docker image
.PHONY: images
images:
	docker build . -f Dockerfile -t $(REGISTRY)/$(IMAGE_NAME):$(BUILD_TAG)
	docker build . -f Dockerfile.orchestrator -t $(REGISTRY)/$(ORCHESTRATOR_IMAGE_NAME):$(BUILD_TAG)
	docker build . -f Dockerfile.sidecar -t $(REGISTRY)/$(SIDECAR_MYSQL57_IMAGE_NAME):$(BUILD_TAG)
	docker build . -f Dockerfile.sidecar --build-arg XTRABACKUP_PKG=percona-xtrabackup-80 \
					-t $(REGISTRY)/$(SIDECAR_MYSQL8_IMAGE_NAME):$(BUILD_TAG)
	set -e; \
		for tag in $(IMAGE_TAGS); do \
			docker tag $(REGISTRY)/$(IMAGE_NAME):$(BUILD_TAG) $(REGISTRY)/$(IMAGE_NAME):$${tag}; \
			docker tag $(REGISTRY)/$(ORCHESTRATOR_IMAGE_NAME):$(BUILD_TAG) $(REGISTRY)/$(ORCHESTRATOR_IMAGE_NAME):$${tag}; \
			docker tag $(REGISTRY)/$(SIDECAR_MYSQL57_IMAGE_NAME):$(BUILD_TAG) $(REGISTRY)/$(SIDECAR_MYSQL57_IMAGE_NAME):$${tag}; \
			docker tag $(REGISTRY)/$(SIDECAR_MYSQL8_IMAGE_NAME):$(BUILD_TAG) $(REGISTRY)/$(SIDECAR_MYSQL8_IMAGE_NAME):$${tag}; \
	done

# Push the docker image
.PHONY: publish
publish: images
	set -e; \
		for tag in $(IMAGE_TAGS); do \
		docker push $(REGISTRY)/$(IMAGE_NAME):$${tag}; \
		docker push $(REGISTRY)/$(ORCHESTRATOR_IMAGE_NAME):$${tag}; \
		docker push $(REGISTRY)/$(SIDECAR_MYSQL57_IMAGE_NAME):$${tag}; \
		docker push $(REGISTRY)/$(SIDECAR_MYSQL8_IMAGE_NAME):$${tag}; \
	done

# E2E tests
###########

KUBECONFIG ?= ~/.kube/config
K8S_CONTEXT ?= minikube

e2e-local: images
	go test ./test/e2e -v $(G_ARGS) -timeout 20m --pod-wait-timeout 60 \
		-ginkgo.slowSpecThreshold 300 \
		--kubernetes-config $(KUBECONFIG) --kubernetes-context $(K8S_CONTEXT) \
		--report-dir ../../e2e-reports

E2E_IMG_TAG ?= $(APP_VERSION)
e2e-remote:
	go test ./test/e2e -v $(G_ARGS) -timeout 50m --pod-wait-timeout 200 \
		-ginkgo.slowSpecThreshold 300 \
		--kubernetes-config $(KUBECONFIG) --kubernetes-context $(K8S_CONTEXT) \
		--report-dir ../../e2e-reports \
		--operator-image quay.io/presslabs/mysql-operator:$(E2E_IMG_TAG) \
		--sidecar-mysql57-image  quay.io/presslabs/mysql-operator-sidecar-mysql57:$(E2E_IMG_TAG) \
		--sidecar-mysql8-image  quay.io/presslabs/mysql-operator-sidecar-mysql8:$(E2E_IMG_TAG) \
		--orchestrator-image  quay.io/presslabs/mysql-operator-orchestrator:$(E2E_IMG_TAG)
