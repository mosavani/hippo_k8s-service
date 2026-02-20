# Helm Template Helpers (`*.tpl` files)

The `.tpl` files in `hippo-service/templates/defines/` are **Helm named template libraries** — they define reusable functions that other templates call via `{{ include "..." . }}`.

Helm renders every file inside `templates/`, but files prefixed with `_` are treated as **partials only** — they produce no output themselves and never appear in the final manifests.

---

## Files Overview

| File | Purpose |
|---|---|
| `_hippo.labels.tpl` | Name and label helpers used by every resource |
| `_hippo.affinity.tpl` | Pod anti-affinity and node affinity block generation |
| `_hippo.rollout.tpl` | Argo Rollouts canary step rendering |

---

## `_hippo.labels.tpl`

Defines label and name helpers used by every resource in the chart.

| Template | Used by | Output |
|---|---|---|
| `hippo.name` | all templates | Short name from `global.componentName` or release name, max 63 chars |
| `hippo.fullname` | all templates | `<release>-<component>`, max 63 chars — used as the Kubernetes resource name |
| `hippo.labels` | `metadata.labels` of every object | Full label set: `app.kubernetes.io/*`, `hippo/env`, `hippo/cluster` |
| `hippo.selectorLabels` | Deployment/Rollout `matchLabels`, Service `selector` | The two labels that must match between pods and Services |

Without this file, every template would repeat the same label logic. One change here propagates to all resources automatically.

**Example output of `hippo.labels`:**

```yaml
app.kubernetes.io/name: hippo-api
app.kubernetes.io/instance: hippo-release
app.kubernetes.io/version: "2.0.0"
app.kubernetes.io/managed-by: Helm
hippo/env: prod
```

**Example output of `hippo.selectorLabels`:**

```yaml
app.kubernetes.io/name: hippo-api
app.kubernetes.io/instance: hippo-release
```

---

## `_hippo.affinity.tpl`

Builds the `affinity:` block for pod specs in `deployment.yaml` and `rollout.yaml`. Controlled entirely by two values:

```yaml
affinity:
  podAntiAffinity: soft   # soft | hard | none
  nodePool: ""            # optional GKE node pool name
```

| Template | What it generates |
|---|---|
| `hippo.affinity` | Full `affinity:` block combining pod anti-affinity and node affinity |

### Pod anti-affinity modes

**`soft`** — prefers different nodes and zones, but won't block scheduling if unavailable:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              app.kubernetes.io/name: hippo-api
              app.kubernetes.io/instance: hippo-release
          topologyKey: kubernetes.io/hostname
      - weight: 50
        podAffinityTerm:
          ...
          topologyKey: topology.kubernetes.io/zone
```

**`hard`** — requires pods to land on different nodes; scheduling fails if impossible (use for prod HA):

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: hippo-api
            app.kubernetes.io/instance: hippo-release
        topologyKey: kubernetes.io/hostname
```

**`none`** — no anti-affinity rules rendered at all.

### Node pool pin

When `affinity.nodePool` is set, a `nodeAffinity` block is appended that pins pods to a specific GKE node pool:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: cloud.google.com/gke-nodepool
              operator: In
              values:
                - "high-mem-pool"
```

---

## `_hippo.rollout.tpl`

Renders the `steps:` block inside `rollout.yaml`'s canary strategy section. Controlled by `rollout.steps[]` in values.

| Template | What it generates |
|---|---|
| `hippo.rollout.steps` | Iterates `rollout.steps[]` and emits the correct Argo Rollouts YAML for each step type |

### Supported step types

| Values input | Rendered output |
|---|---|
| `- setWeight: 20` | `- setWeight: 20` |
| `- pause: { duration: 60s }` | `- pause:` / `    duration: 60s` |
| `- pause: {}` | `- pause: {}` (indefinite — requires manual `kubectl argo rollouts promote`) |
| `- analysis: { templates: [...] }` | Full `analysis:` step with template refs and args |

**Example values:**

```yaml
rollout:
  steps:
    - setWeight: 10
    - pause:
        duration: 60s
    - setWeight: 50
    - pause:
        duration: 120s
    - setWeight: 100
```

**Rendered output:**

```yaml
steps:
  - setWeight: 10
  - pause:
      duration: 60s
  - setWeight: 50
  - pause:
      duration: 120s
  - setWeight: 100
```

The step logic lives in a helper rather than inline in `rollout.yaml` because checking which key is present per step (setWeight vs pause vs analysis) and handling edge cases like empty pause maps would make the main template hard to read.

---

## How the templates connect

```
deployment.yaml      ── include "hippo.labels"         ──→ _hippo.labels.tpl
                     ── include "hippo.selectorLabels"  ──→ _hippo.labels.tpl
                     ── include "hippo.fullname"         ──→ _hippo.labels.tpl
                     ── include "hippo.affinity"         ──→ _hippo.affinity.tpl

rollout.yaml         ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.affinity"         ──→ _hippo.affinity.tpl
                     ── include "hippo.rollout.steps"    ──→ _hippo.rollout.tpl

service.yaml         ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.selectorLabels"  ──→ _hippo.labels.tpl

service-rollout.yaml ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.selectorLabels"  ──→ _hippo.labels.tpl

hpa.yaml             ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.fullname"         ──→ _hippo.labels.tpl

pdb.yaml             ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.selectorLabels"  ──→ _hippo.labels.tpl

ingress.yaml         ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.fullname"         ──→ _hippo.labels.tpl

netpolicies.yaml     ── include "hippo.labels"          ──→ _hippo.labels.tpl
                     ── include "hippo.selectorLabels"  ──→ _hippo.labels.tpl
```

---

## Adding a new helper

1. Create a new file in `templates/defines/` prefixed with `_hippo.`:
   ```
   hippo-service/templates/defines/_hippo.myhelper.tpl
   ```

2. Define the template using `{{- define "hippo.myhelper" -}}`:
   ```
   {{- define "hippo.myhelper" -}}
   myKey: {{ .Values.myValue | quote }}
   {{- end }}
   ```

3. Call it from any template:
   ```yaml
   spec:
     {{- include "hippo.myhelper" . | nindent 4 }}
   ```

The `.` passes the full render context (Values, Release, Chart, etc.) into the helper. Use `nindent N` to control indentation at the call site rather than inside the helper — this keeps helpers reusable across different indentation levels.
