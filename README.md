# vCluster Bare Metal with KubeVirt

Run vCluster's metal3 bare metal node provider locally using KubeVirt VMs as fake bare metal servers.

## Prerequisites

- Docker
- [vcluster CLI](https://www.vcluster.com/docs/getting-started/setup)
- kubectl
- helm
- A host with KVM/hypervisor support and enough resources for the VMs (~16GB RAM, 4+ CPU cores)

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
# You will be prompted for a platform license token on first run.
make install

# Wait a minute for the NodeProvider to deploy Metal3, Ironic, and the DHCP server.
sleep 60

# Create the KubeVirt VMs, BMC deployments & BareMetalHost resources
make create-vms
```

## Usage

### Provision BareMetalHosts manually

After `make create-vms`, the BareMetalHost resources appear in the platform UI.
You can inspect, provision, or deprovision them from there.

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

The vCluster uses kube-vip on the bridge network and requests nodes from the metal3 NodeProvider.

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

## Tear Down

```bash
make vind-down
```

This deletes the vcluster-in-docker cluster and removes the local kubeconfig file. All state (VMs, BMHs, platform data) lives inside the cluster and is gone with it.
