{{/*
============================================================
_hippo.affinity.tpl — Pod/node affinity helpers
============================================================
*/}}

{{/*
Pod anti-affinity (soft or hard) + optional node pool pin.
Usage: {{ include "hippo.affinity" . }}
*/}}
{{- define "hippo.affinity" -}}
{{- $mode := .Values.affinity.podAntiAffinity | default "soft" }}
{{- $nodePool := .Values.affinity.nodePool | default "" }}
{{- if or (ne $mode "none") $nodePool }}
affinity:
  {{- if ne $mode "none" }}
  podAntiAffinity:
    {{- if eq $mode "hard" }}
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            {{- include "hippo.selectorLabels" . | nindent 12 }}
        topologyKey: kubernetes.io/hostname
    {{- else }}
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchLabels:
              {{- include "hippo.selectorLabels" . | nindent 14 }}
          topologyKey: kubernetes.io/hostname
      - weight: 50
        podAffinityTerm:
          labelSelector:
            matchLabels:
              {{- include "hippo.selectorLabels" . | nindent 14 }}
          topologyKey: topology.kubernetes.io/zone
    {{- end }}
  {{- end }}
  {{- if $nodePool }}
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: cloud.google.com/gke-nodepool
              operator: In
              values:
                - {{ $nodePool | quote }}
  {{- end }}
{{- end }}
{{- end }}
