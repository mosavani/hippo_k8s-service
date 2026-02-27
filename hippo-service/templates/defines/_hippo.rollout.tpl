{{/*
============================================================
_hippo.rollout.tpl — Argo Rollouts canary helpers
============================================================
*/}}

{{/*
hippo.rollout.enabled — returns true when rollout is enabled.
Accepts:
  - boolean true
  - string "true"
  - string "progressive" (injected by ArgoCD ApplicationSet via {{deployment_type}})
Usage: {{- if include "hippo.rollout.enabled" . }}
*/}}
{{- define "hippo.rollout.enabled" -}}
{{- $v := .Values.rollout.enabled | toString -}}
{{- if or (eq $v "true") (eq $v "progressive") -}}
true
{{- end -}}
{{- end -}}

{{/*
Render the analysis templates block for auto-injected analysis steps.
Outputs the `templates:` list for any enabled default analysis checks.
Usage: {{ include "hippo.rollout.analysisBlock" . }}
*/}}
{{- define "hippo.rollout.analysisBlock" -}}
- analysis:
    templates:
{{- if .Values.rollout.analysis.defaultCpuUsage.threshold }}
      - templateName: {{ printf "%s-cpu-usage" (include "hippo.fullname" .) | quote }}
{{- end }}
{{- if .Values.rollout.analysis.defaultMemoryUtilization.threshold }}
      - templateName: {{ printf "%s-memory-utilization" (include "hippo.fullname" .) | quote }}
{{- end }}
    args:
      - name: canary-hash
        valueFrom:
          podTemplateHashValue: Latest
{{- end -}}

{{/*
Render canary steps from .Values.rollout.steps.
Each step is a map with exactly one key: setWeight | pause | analysis.

If rollout.analysis.defaultCpuUsage.threshold or defaultMemoryUtilization.threshold
are set, an inline `analysis` step is automatically injected after every `setWeight`
step so that each traffic increment is validated before the next pause/weight.

Usage: {{ include "hippo.rollout.steps" . }}
*/}}
{{- define "hippo.rollout.steps" -}}
{{- $hasCpu := .Values.rollout.analysis.defaultCpuUsage.threshold -}}
{{- $hasMem := .Values.rollout.analysis.defaultMemoryUtilization.threshold -}}
{{- $hasAnalysis := or $hasCpu $hasMem -}}
{{- range .Values.rollout.steps }}
{{- if hasKey . "setWeight" }}
- setWeight: {{ .setWeight }}
{{- else if hasKey . "pause" }}
- pause:
  {{- if .pause.duration }}
    duration: {{ .pause.duration }}
  {{- else }} {}
  {{- end }}
{{- if $hasAnalysis }}
{{ include "hippo.rollout.analysisBlock" $ }}
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
