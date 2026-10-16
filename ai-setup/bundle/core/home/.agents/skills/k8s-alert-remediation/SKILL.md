---
name: k8s-alert-remediation
description: Use when investigating, remediating, or verifying active Kubernetes Alertmanager alerts across kubeconfig contexts.
---

# K8s Alert Remediation

Investigate alerts across every currently configured context, establish root cause before remediation, and prove the active alert has cleared.

## Discover alerts

1. List contexts dynamically with `kubectl config get-contexts -o name`; do not hardcode cluster names.
2. For each context, discover the Alertmanager and Prometheus services. When the standard kube-prometheus-stack services exist, query Alertmanager with `kubectl --context "$context" get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false'`. If they do not, inspect services before assuming a URL.
3. Query only active, unsilenced, uninhibited Alertmanager alerts. Record alert name, severity, labels, annotations, start time, and generator URL.
4. Treat `Watchdog` and `InfoInhibitor` as synthetic signals only after confirming that cluster's rules/configuration establish that purpose. Report them separately.
5. If a context cannot reach or authenticate to its API, report it as unavailable with the exact safe error; do not mistake the access failure for an alert or alter credentials without authorization.

## Diagnose before changing

For every actionable alert, inspect the alert rule and its input, workload status, recent events and logs, resource pressure, and relevant GitOps history. Correlate identifiers precisely (including pod UID where restart history is involved); do not infer a current failure from a deleted workload.

Prefer a durable GitOps-source change when Argo CD or another reconciler owns the resource. Do not use an Alertmanager silence as a fix. Do not delete workloads or force-restart stateful, storage, or data-plane components. Roll those components one healthy member at a time and check their service health between changes.

Respect the user's authorization at the operation boundary: read-only diagnosis is safe, but mutating a cluster, silencing an alert, committing, or pushing requires a request that specifically authorizes it. Stop and explain if remediation would risk data loss, require credential changes, or needs a material operational choice.

## Verify and report

After a change and the relevant rollout/health checks, re-query both Prometheus and Alertmanager in the affected context. Do not claim resolution until the alert is absent or no longer firing in both places. Summarize each context, root cause, durable change, verification evidence, and unresolved risks.
