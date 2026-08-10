.PHONY: vind-up vind-down install install-cert-manager install-cni-static install-kubevirt install-bridge install-platform reset-admin-password install-os-image install-ssh-key install-node-provider install-network-environment create-vms create-machine create-vcluster create-ssh-service

CLUSTER_NAME ?= bare-metal-fun
KUBECONFIG := $(CURDIR)/kubeconfig
export KUBECONFIG

PLATFORM_VERSION ?= 4.8.0
CERT_MANAGER_VERSION ?= v1.19.2
KUBEVIRT_VERSION ?= v1.7.1
CDI_VERSION ?= v1.64.0

vind-up:
	vcluster --driver docker create $(CLUSTER_NAME)
	vcluster --driver docker connect $(CLUSTER_NAME) --print > $(KUBECONFIG)

vind-down:
	vcluster --driver docker delete $(CLUSTER_NAME)
	rm -f $(KUBECONFIG)

install: install-cert-manager install-cni-static install-kubevirt install-bridge install-platform reset-admin-password install-os-image install-ssh-key install-node-provider install-network-environment

install-cert-manager:
	helm upgrade --install cert-manager cert-manager \
		--repo https://charts.jetstack.io \
		--namespace cert-manager \
		--create-namespace \
		--version $(CERT_MANAGER_VERSION) \
		--set crds.enabled=true \
		--wait

install-cni-static:
	kubectl apply -f manifests/cni-static-plugin.yaml
	kubectl rollout status daemonset/cni-static-plugin -n kube-system --timeout=120s

install-kubevirt:
	kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-operator.yaml
	kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/$(KUBEVIRT_VERSION)/kubevirt-cr.yaml
	kubectl wait --for=condition=Available --timeout=300s -n kubevirt deployment/virt-operator
	kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$(CDI_VERSION)/cdi-operator.yaml
	kubectl apply -f https://github.com/kubevirt/containerized-data-importer/releases/download/$(CDI_VERSION)/cdi-cr.yaml
	kubectl wait --for=condition=Available --timeout=300s -n cdi deployment/cdi-operator

install-bridge:
	kubectl apply -f manifests/bridge-setup.yaml

install-platform:
	if [ -z "$$LICENSE_TOKEN" ]; then \
		read -p "Enter platform license token (leave empty to reuse existing): " LICENSE_TOKEN; \
	fi; \
	if [ -n "$$LICENSE_TOKEN" ]; then \
		LICENSE_FLAGS="--set env.LICENSE_TOKEN=$$LICENSE_TOKEN"; \
	else \
		LICENSE_FLAGS="--reuse-values"; \
	fi; \
	echo $$LICENSE_FLAGS; \
	helm upgrade --install vcluster-platform \
		--repo https://charts.loft.sh/ vcluster-platform \
		--version $(PLATFORM_VERSION) \
		--namespace vcluster-platform \
		--create-namespace \
		--values manifests/platform-values.yaml \
		$$LICENSE_FLAGS \
		--wait

reset-admin-password:
	vcluster platform reset password --user admin

create-vms:
	helm upgrade --install vm vm/ --namespace default

install-os-image:
	kubectl apply -f manifests/os-image.yaml

install-ssh-key:
	kubectl apply -f manifests/ssh-key.yaml

install-node-provider:
	kubectl apply -f manifests/node-provider.yaml
	# The platform deploys Multus and the DHCP proxy asynchronously in response to
	# the NodeProvider above. If the DHCP proxy pod's sandbox is created before
	# Multus's CNI config is written to /etc/cni/net.d, it silently loses the
	# race and never gets its br0/net1 interface for the lifetime of that pod
	# (CNI attachment happens once, at sandbox creation, and doesn't retry).
	# Wait for Multus, then force a clean recreate so it can't have lost the race.
	# --for=create is required here: the DaemonSet doesn't exist yet immediately
	# after the apply above (the platform creates it asynchronously), and plain
	# `kubectl wait` errors NotFound instead of blocking on a resource that
	# doesn't exist yet. --for=create is always waited first when combined with
	# another --for condition, so this waits for the object to appear and then
	# for it to actually be ready, within the one timeout.
	kubectl wait --for=create --for=jsonpath='{.status.numberReady}'=1 daemonset/kube-multus-ds -n default --timeout=180s || true
	kubectl delete pod -n default dhcp-proxy-0 --ignore-not-found

install-network-environment:
	kubectl apply -f manifests/node-environment.yaml

create-machine:
	kubectl apply -f manifests/node-claim.yaml

create-vcluster:
	kubectl apply -f manifests/vcluster.yaml

create-ssh-service:
	$(eval BMH_IP := $(shell kubectl get baremetalhost -n default -l metal3.vcluster.com/node-claim \
		-o jsonpath='{.items[0].metadata.annotations.metal3\.vcluster\.com/ip-address}' | cut -d/ -f1))
	@echo "Targeting claimed BareMetalHost at $(BMH_IP)"
	sed "s/PLACEHOLDER_IP/$(BMH_IP)/" manifests/ssh-service.yaml | kubectl apply -f -
