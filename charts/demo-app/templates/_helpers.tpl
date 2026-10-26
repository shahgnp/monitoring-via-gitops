{{- define "demo.labels" -}}
app.kubernetes.io/name: demo-app
app.kubernetes.io/instance: {{ .Values.tenant }}
{{- end -}}

{{/* Structured access log: the golden-signals dashboard parses status and request_time from it. */}}
{{- define "demo.nginxConf" -}}
log_format sre escape=json '{"ts":"$time_iso8601","method":"$request_method","uri":"$uri","status":$status,"request_time":$request_time,"bytes_sent":$body_bytes_sent}';
server {
  listen 8080;
  access_log /dev/stdout sre;
  location = /stub_status {
    access_log off;
    stub_status;
    allow 127.0.0.1;
    deny all;
  }
  location = /error {
    return 500 "simulated error from {{ .Values.tenant }}\n";
  }
  location = /unavailable {
    return 503 "simulated overload from {{ .Values.tenant }}\n";
  }
  location = /payload {
    default_type text/plain;
    return 200 "{{ repeat 300 "0123456789" }}\n";
  }
  location = /health {
    access_log off;
    return 200 "ok\n";
  }
  location / {
    default_type text/plain;
    return 200 "hello from {{ .Values.tenant }}\n";
  }
}
{{- end -}}
