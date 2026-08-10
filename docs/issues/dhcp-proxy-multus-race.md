## Title
DHCP proxy pod can permanently lose its Multus network attachment due to a startup race with Multus's CNI config

## Summary
When the `metal3` NodeProvider deploys Multus, Metal3/Ironic, and the DHCP proxy together, the DHCP proxy StatefulSet's pod can be scheduled and have its network namespace created *before* Multus's CNI config (`00-multus.conf`) is written to `/etc/cni/net.d` on the node. When that happens, the pod's sandbox is created using only the primary CNI plugin (e.g. flannel), silently ignoring its `k8s.v1.cni.cncf.io/networks` annotation — it never gets the `br0`/static-IP secondary interface it needs to serve DHCP/TFTP.

Because Kubernetes only invokes CNI `ADD` once, at pod sandbox creation, this isn't self-healing: the container will crash-loop indefinitely (failing to bind its DHCP/TFTP listener to the VIP), and restarting the container does not retry network attachment. Only deleting and recreating the *pod* (not just the container) triggers a fresh CNI `ADD`, at which point it picks up the correct interface if Multus has become ready in the meantime.

## Impact
Since this pod provides DHCP/PXE for the bare-metal provisioning network, this failure mode silently blocks all Ironic hardware inspection — affected `BareMetalHost` resources sit in `inspecting` state indefinitely with no error surfaced anywhere in the BMH status, since from Ironic's point of view it's just waiting on a callback that will never arrive. The actual cause (DHCP proxy pod's Multus attachment) is several hops away from the symptom (VM won't boot / BMH won't leave `inspecting`), making this very difficult to diagnose without deep familiarity with the stack.

## Root cause
Whatever chart/reconciler deploys the `dhcp-proxy` StatefulSet as part of `NodeProvider.spec.metal3.deploy.dhcp` has no ordering dependency on Multus's DaemonSet rollout — it applies the DHCP StatefulSet concurrently with (or possibly before) Multus finishing its own DaemonSet rollout across the node(s). This is a classic Kubernetes multi-CNI race: Multus needs to have already written its config as the first entry in `/etc/cni/net.d` for kubelet to invoke it (as the meta-plugin) instead of the primary CNI, for any pod scheduled after that point.

Confirmed via direct timestamp comparison in a repro: the DHCP proxy pod's sandbox was created at `17:37:55Z`; Multus's `00-multus.conf` was written at `17:37:56.08` — under a second later. Deleting the pod after Multus was confirmed `Ready` immediately fixed it (the recreated pod correctly got `net1`/its static IP), confirming both the race and the fix.

## Suggested fix
Add an explicit ordering dependency so the DHCP StatefulSet (and any other workload with a Multus-dependent secondary network) is not created until Multus's DaemonSet has finished rolling out on the relevant node(s). Concretely, in whatever chart owns this deploy:

- Add a `helm.sh/hook: pre-install,pre-upgrade` Job that runs something equivalent to:
  ```bash
  kubectl rollout status daemonset/kube-multus-ds -n <namespace> --timeout=180s
  ```
  and blocks the release from proceeding (or at minimum blocks creation of the DHCP StatefulSet specifically) until that succeeds.
- Alternatively, if the reconciler is a custom controller rather than a Helm release, gate creation of the DHCP StatefulSet on an explicit readiness check of the Multus DaemonSet before calling `Create`, with a retry/requeue if not yet ready.

Either approach converts an unbounded, silent failure mode into a bounded, visible wait during initial provisioning — much easier to reason about than a race that only manifests intermittently depending on exact scheduling timing.

## Workaround (already applied downstream)
In [vcluster-bare-metal-with-kubevirt](https://github.com/loft-sh/vcluster-bare-metal-with-kubevirt), `make install-node-provider` now waits for `daemonset/kube-multus-ds` to report ready and then force-deletes `dhcp-proxy-0` defensively, to close this window for that specific demo repo. This is a band-aid at the consuming-repo level and doesn't fix the underlying ordering gap for other NodeProvider deploys, custom or otherwise.

## How to reproduce
1. Create a `NodeProvider` with `spec.metal3.deploy.{multus,metal3,dhcp}.enabled: true` on a cluster where Multus is not yet installed.
2. Immediately watch `kubectl get pod -n <ns> dhcp-proxy-0 -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'` — on a fast/lightly-loaded cluster this can come back empty, showing only the pod's primary interface.
3. Confirm via `kubectl logs -n <ns> dhcp-proxy-0 -c server --previous`: a `bind: cannot assign requested address` error for the pod's expected VIP confirms the missing secondary interface.
4. Confirm the fix: after Multus is `Ready`, `kubectl delete pod -n <ns> dhcp-proxy-0` and re-check — the recreated pod gets its `net1` interface correctly.
