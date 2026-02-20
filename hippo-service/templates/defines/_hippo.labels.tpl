{{/*
============================================================
_hippo.labels.tpl — Standard label helpers
============================================================
*/}}

{{/*
Chart name — uses componentName if set, otherwise release name.
*/}}
{{- define "hippo.name" -}}
{{- .Values.global.componentName | default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name.
*/}}
{{- define "hippo.fullname" -}}
{{- printf "%s-%s" .Release.Name (.Values.global.componentName | default .Release.Name) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "hippo.labels" -}}
app.kubernetes.io/name: {{ include "hippo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
hippo/env: {{ .Values.global.env | default "dev" }}
{{- end }}

{{/*
Selector labels — used by Services and Deployments to match pods.
*/}}
{{- define "hippo.selectorLabels" -}}
app.kubernetes.io/name: {{ include "hippo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
