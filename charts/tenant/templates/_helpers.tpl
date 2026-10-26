{{/* Fail fast when a tenant file is incomplete. */}}
{{- define "tenant.validate" -}}
{{- required "tenant is required" .Values.tenant -}}
{{- required "namespace is required" .Values.namespace -}}
{{- required "at least one member is required" .Values.members -}}
{{- end -}}
