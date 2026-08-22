{{- define "domarchy.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "domarchy.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "domarchy.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "domarchy.labels" -}}
helm.sh/chart: {{ include "domarchy.chart" . }}
{{ include "domarchy.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "domarchy.selectorLabels" -}}
app.kubernetes.io/name: {{ include "domarchy.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Name of the claim holding the ISO and qcow2 */}}
{{- define "domarchy.dataClaim" -}}
{{- if .Values.persistence.existingClaim }}
{{- .Values.persistence.existingClaim }}
{{- else }}
{{- printf "%s-data" (include "domarchy.fullname" .) }}
{{- end }}
{{- end }}

{{- define "domarchy.sharedClaim" -}}
{{- if .Values.shared.existingClaim }}
{{- .Values.shared.existingClaim }}
{{- else }}
{{- printf "%s-shared" (include "domarchy.fullname" .) }}
{{- end }}
{{- end }}
