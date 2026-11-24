{{- define "monte-carlo.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "monte-carlo.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "monte-carlo.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "monte-carlo.labels" -}}
app.kubernetes.io/name: {{ include "monte-carlo.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "monte-carlo.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{- define "monte-carlo.runName" -}}
{{- printf "%s-%s" .Release.Name .Values.run.id | trunc 58 | trimSuffix "-" }}
{{- end }}

{{- define "monte-carlo.resultDeliveryMode" -}}
{{- $mode := default "fss" .Values.resultDelivery.mode -}}
{{- if not (has $mode (list "object_storage" "fss")) -}}
{{- fail "resultDelivery.mode must be object_storage or fss" -}}
{{- end -}}
{{- $mode -}}
{{- end }}
