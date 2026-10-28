{{- define "africair.fullname" -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}

{{- define "africair.labels" -}}
app.kubernetes.io/part-of: africair
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "africair.tag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/* selectorLabels <component> */}}
{{- define "africair.selector" -}}
app.kubernetes.io/name: {{ .component }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
{{- end -}}

{{- define "africair.tag" -}}
{{- default .Chart.AppVersion .Values.image.tag -}}
{{- end -}}

{{/* image <name> */}}
{{- define "africair.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- if $registry }}{{ printf "%s/%s:%s" $registry .name (include "africair.tag" .root) }}{{ else }}{{ printf "%s:%s" .name (include "africair.tag" .root) }}{{ end -}}
{{- end -}}

{{- define "africair.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "africair.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/*
Ordering: ExternalSecrets → migration Job → Deployments.
  helm:   ExternalSecrets and the Job are pre-install/pre-upgrade hooks (weights -10, 0); the migrate SA -20.
  gitops: Argo CD runs the whole PreSync phase before the Sync phase, so a PreSync migration would start
          before any wave of normal resources and find no database Secret. Instead the ExternalSecrets are
          normal resources in wave -1 (so their health counts), the Job is a Sync hook in wave 0 and the
          Deployments are in wave 1.
Usage: include "africair.ordering" (dict "root" . "weight" "-10" "job" false)
*/}}
{{- define "africair.ordering" -}}
{{- if .root.Values.gitops.enabled }}
{{- if .job }}
argocd.argoproj.io/hook: Sync
argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
argocd.argoproj.io/sync-wave: "0"
{{- else }}
argocd.argoproj.io/sync-wave: "-1"
{{- end }}
{{- else }}
helm.sh/hook: pre-install,pre-upgrade
helm.sh/hook-weight: {{ .weight | quote }}
helm.sh/hook-delete-policy: before-hook-creation
{{- end }}
{{- end -}}

{{/* Hooks are re-created on every upgrade: their Secret must survive that (Orphan). */}}
{{- define "africair.creationPolicy" -}}
{{- if .Values.gitops.enabled }}Owner{{ else }}Orphan{{ end -}}
{{- end -}}
