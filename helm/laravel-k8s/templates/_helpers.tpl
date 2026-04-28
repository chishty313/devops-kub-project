{{/*
Common helpers for the laravel-k8s chart.
*/}}

{{/* Chart name truncated to 63 chars for label safety. */}}
{{- define "laravel-k8s.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified release name. */}}
{{- define "laravel-k8s.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Chart label. */}}
{{- define "laravel-k8s.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels — must be stable across upgrades. */}}
{{- define "laravel-k8s.selectorLabels" -}}
app.kubernetes.io/name: {{ include "laravel-k8s.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* Full label set for non-selector matching. */}}
{{- define "laravel-k8s.labels" -}}
helm.sh/chart: {{ include "laravel-k8s.chart" . }}
{{ include "laravel-k8s.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: laravel-k8s
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Common annotations. */}}
{{- define "laravel-k8s.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Resolved namespace name. */}}
{{- define "laravel-k8s.namespace" -}}
{{- default .Release.Namespace .Values.namespace.name -}}
{{- end -}}

{{/* ServiceAccount name. */}}
{{- define "laravel-k8s.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "laravel-k8s.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* ConfigMap name (env). */}}
{{- define "laravel-k8s.configMapName" -}}
{{- printf "%s-env" (include "laravel-k8s.fullname" .) -}}
{{- end -}}

{{/* Secret name (env). */}}
{{- define "laravel-k8s.secretName" -}}
{{- printf "%s-env" (include "laravel-k8s.fullname" .) -}}
{{- end -}}

{{/* PVC name. */}}
{{- define "laravel-k8s.pvcName" -}}
{{- printf "%s-storage" (include "laravel-k8s.fullname" .) -}}
{{- end -}}

{{/*
envFrom block shared by web / queue / scheduler / migration:
combines ConfigMap (non-secret) and Secret (sensitive) into the env.
*/}}
{{- define "laravel-k8s.envFrom" -}}
- configMapRef:
    name: {{ include "laravel-k8s.configMapName" . }}
- secretRef:
    name: {{ include "laravel-k8s.secretName" . }}
{{- end -}}

{{/* Image pull secrets (combination of pre-created + chart-rendered). */}}
{{- define "laravel-k8s.imagePullSecrets" -}}
{{- $secrets := list -}}
{{- range .Values.image.pullSecrets -}}
{{- $secrets = append $secrets (dict "name" .) -}}
{{- end -}}
{{- if .Values.imagePullSecret.create -}}
{{- $secrets = append $secrets (dict "name" .Values.imagePullSecret.name) -}}
{{- end -}}
{{- if $secrets -}}
imagePullSecrets:
{{ toYaml $secrets }}
{{- end -}}
{{- end -}}
