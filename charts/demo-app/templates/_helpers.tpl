{{- define "demo.labels" -}}
app.kubernetes.io/name: demo-app
app.kubernetes.io/instance: {{ .Values.tenant }}
{{- end -}}
