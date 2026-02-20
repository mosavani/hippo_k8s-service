{{/*
============================================================
_hippo.rollout.tpl — Argo Rollouts canary helpers
============================================================
*/}}

{{/*
Render canary steps from .Values.rollout.steps.
Each step is a map with exactly one key: setWeight | pause | analysis.
Usage: {{ include "hippo.rollout.steps" . }}
*/}}
{{- define "hippo.rollout.steps" -}}
{{- range .Values.rollout.steps }}
{{- if hasKey . "setWeight" }}
- setWeight: {{ .setWeight }}
{{- else if hasKey . "pause" }}
- pause:
  {{- if .pause.duration }}
    duration: {{ .pause.duration }}
  {{- else }} {}
  {{- end }}
{{- else if hasKey . "analysis" }}
- analysis:
    templates:
    {{- range .analysis.templates }}
      - templateName: {{ .templateName | quote }}
    {{- end }}
    {{- if .analysis.args }}
    args:
      {{- toYaml .analysis.args | nindent 6 }}
    {{- end }}
{{- end }}
{{- end }}
{{- end }}
