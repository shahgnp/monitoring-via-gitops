{{/* Fail fast when a tenant file is incomplete. */}}
{{- define "tenant.validate" -}}
{{- required "tenant is required" .Values.tenant -}}
{{- required "namespace is required" .Values.namespace -}}
{{- required "grafana.login is required" .Values.grafana.login -}}
{{- required "grafana.password is required" .Values.grafana.password -}}
{{- end -}}

{{- define "tenant.proxyName" -}}
prom-label-proxy-{{ .Values.tenant }}
{{- end -}}
