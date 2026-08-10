# vCluster Bare Metal with KubeVirt

Run vCluster's metal3 bare metal node provider locally using KubeVirt VMs as fake bare metal servers.

## Prerequisites

- Docker
- [vcluster CLI](https://www.vcluster.com/docs/getting-started/setup)
- kubectl
- helm
- A host with KVM/hypervisor support and enough resources for the VMs (~16GB RAM, 4+ CPU cores)

### Sizing note

The ~16GB/4-core figure above is for the two default VMs *alone* (each requests
2 CPU cores / 4Gi memory — see `vm/values.yaml`). It does not include the
platform's own footprint: cert-manager, KubeVirt, CDI, Metal3, Ironic,
vCluster Platform, and Prometheus together typically consume another
~3 CPU cores / ~5Gi memory on the single vind node before you even create a
VM. Size your host for VM requirements *plus* that overhead, with some margin
for the later `make create-vcluster` step, which adds a Tenant Cluster control
plane on top. In practice this means a real-world minimum closer to 8 vCPU /
16GB, and more comfortably 16 vCPU / 32GB.

If you're provisioning the host on AWS with Terraform and using `cpu_options`
to enable nested virtualization (required for KubeVirt to get real `/dev/kvm`
access — supported on 8th-gen Intel families: c8i/m8i/r8i and flex variants),
note that `core_count` and `threads_per_core` are **required together** by
AWS whenever `cpu_options` is set at all, and they silently override the
instance type's native vCPU count if they don't match it. A hardcoded
`core_count` left over from a smaller instance type will cap you at that
smaller CPU count forever, no matter how large an instance type you pick —
and unlike memory, there's no error, it just quietly under-provisions you.
Prefer computing it from the instance type instead of hardcoding it:

```hcl
data "aws_ec2_instance_type" "selected" {
  instance_type = var.instance_type
}

resource "aws_instance" "this" {
  instance_type = var.instance_type
  # ...

  cpu_options {
    core_count             = data.aws_ec2_instance_type.selected.default_cores
    threads_per_core       = data.aws_ec2_instance_type.selected.default_threads_per_core
    nested_virtualization  = "enabled"
  }
}
```

## Setup

- **KubeVirt VMs** with a Redfish BMC shim (`virtbmc`) acting as fake bare metal servers
- A **Linux bridge** (`br0`, `192.168.100.0/24`) on the node as the shared provisioning and tenant network
- A **metal3 NodeProvider** that auto-deploys Multus, Metal3 + Ironic, and a DHCP server into the host cluster
- A **NodeEnvironment** with IP range `192.168.100.10-192.168.100.20`, gateway `192.168.100.1`, DNS `1.1.1.1`
- An Ubuntu 24.04 **OSImage** and a static **SSHKey**
- **BareMetalHost** resources pointing at the VMs' BMC endpoints

## Quick Start

```bash
# Create a vcluster-in-docker cluster
make vind-up

# Install everything (cert-manager, kubevirt, bridge, platform, node provider, etc.)
# You will be prompted for a valid platform license token.
make install

# Wait for the NodeProvider to deploy Metal3/Ironic (check the platform UI or
# kubectl get statefulset metal3 -n default), then create VMs + BMH resources.
make create-vms
```

## Usage

### Provision BareMetalHosts manually

After `make create-vms`, the BareMetalHost resources appear in the platform UI.
Wait for them to become `available` before provisioning — Ironic needs to inspect each host first, which takes a few minutes.
You can track progress in the UI or with `kubectl get baremetalhost -A`.

To provision a single machine manually:

```bash
make create-machine
```

You may also delete and re-create BareMetalHost resources through the UI.

### Create a vCluster with auto-nodes

This creates a VirtualClusterInstance that automatically provisions bare metal nodes via the metal3 provider:

```bash
make create-vcluster
```

The vCluster uses kube-vip on the bridge network and requests nodes from the metal3 NodeProvider. What happens next:

1. The platform creates a **NodeClaim** for the vCluster — check with `kubectl get nodeclaim -A`
2. A BareMetalHost is selected and **provisioned** (Ironic writes the OS image) — watch with `kubectl get baremetalhost -A`
3. The machine boots, runs cloud-init, and **joins** the vCluster as a node — `kubectl get nodes` against the vCluster

This takes several minutes end-to-end.

### SSH into a provisioned machine

Create a LoadBalancer service that forwards to the provisioned machine's SSH port:

```bash
make create-ssh-service
```

The default IP (`192.168.100.100`) matches if this is the only machine in the network. If not, edit `manifests/ssh-service.yaml` to match the machine's IP.

Then SSH in:

```bash
LB_IP=$(kubectl get svc bare-metal-ssh -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ssh -i ssh-demo-key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@$LB_IP
```

### Individual targets

| Target                      | Description                                      |
|-----------------------------|--------------------------------------------------|
| `make vind-up`              | Create the vcluster-in-docker host cluster       |
| `make vind-down`            | Tear down the host cluster                       |
| `make install`              | Install all infrastructure components            |
| `make create-vms`           | Deploy KubeVirt VMs + BMC StatefulSets           |
| `make create-bmh`           | Create/recreate BareMetalHost resources          |
| `make create-machine`       | Create a Machine/NodeClaim (manual provisioning) |
| `make create-vcluster`      | Create a vCluster with auto-nodes                |
| `make reset-admin-password` | Reset the platform admin password                |

## Troubleshooting

### VMs stuck `Pending` with `Insufficient cpu`/`Insufficient memory`

See the [Sizing note](#sizing-note) above — this is a single-node cluster, so
the platform's own components and the KubeVirt VMs all compete for the same
node's capacity. Check current headroom with:

```bash
kubectl describe node | grep -A10 "Allocated resources"
```

### BareMetalHost stuck in `inspecting` indefinitely

Ironic PXE-boots each host into a diagnostic ramdisk to collect hardware
inventory before marking it `available`. If that never completes, the most
common cause is the `dhcp-proxy` pod (deployed by the `metal3` NodeProvider
alongside Multus) not actually having its `br0`/`192.168.100.4` network
interface — check:

```bash
kubectl get pod -n default dhcp-proxy-0
kubectl logs -n default dhcp-proxy-0 -c server --previous
```

An error like `listen udp 192.168.100.4:69: bind: cannot assign requested
address` means the pod never got its Multus-attached interface. This happens
when the `dhcp-proxy` pod's sandbox is created in the brief window before
Multus's CNI config is written to `/etc/cni/net.d` on the node — Multus being
healthy *afterward* doesn't fix a pod whose network was already set up
without it, since CNI attachment happens once, at sandbox creation, and isn't
retried by restarting the container. `make install-node-provider` now waits
for Multus and recreates the pod defensively to close this window, but if you
hit it anyway (e.g. by re-running `kubectl apply -f manifests/node-provider.yaml`
directly), the fix is the same:

```bash
kubectl wait --for=jsonpath='{.status.numberReady}'=1 daemonset/kube-multus-ds -n default --timeout=180s
kubectl delete pod -n default dhcp-proxy-0
```

You can confirm the fix by checking the pod picked up its second interface:

```bash
kubectl debug -n default dhcp-proxy-0 -it --image=nicolaka/netshoot -- ip addr show
# look for net1 with an address in 192.168.100.0/24
```

Once DHCP is answering, force the stuck host to retry its PXE boot rather
than waiting for it to time out on its own:

```bash
kubectl annotate baremetalhost <name> reboot.metal3.io=""
```

Watch progress without a VM console via the DHCP proxy's logs (shows the live
DHCP/TFTP exchange) or the BareMetalHost's own status:

```bash
kubectl logs -n default dhcp-proxy-0 -c server -f
kubectl describe baremetalhost <name>
```

## Tear Down

```bash
make vind-down
```

This deletes the vcluster-in-docker cluster and removes the local kubeconfig file. All state (VMs, BMHs, platform data) lives inside the cluster and is gone with it.
