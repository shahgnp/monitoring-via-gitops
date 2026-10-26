{{/* The tenant's namespaces as a JSON array: `namespaces`, or the single legacy `namespace`. */}}
{{- define "tenant.namespaces" -}}
{{- if .Values.namespaces -}}
{{- .Values.namespaces | toJson -}}
{{- else if .Values.namespace -}}
{{- list .Values.namespace | toJson -}}
{{- else -}}
[]
{{- end -}}
{{- end -}}

{{/* Fail fast when a tenant file is incomplete. */}}
{{- define "tenant.validate" -}}
{{- required "tenant is required" .Values.tenant -}}
{{- if not (include "tenant.namespaces" . | fromJsonArray) -}}
{{- fail "set `namespaces` (or `namespace`) to at least one namespace" -}}
{{- end -}}
{{- required "at least one member is required" .Values.members -}}
{{- end -}}
