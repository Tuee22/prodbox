{{- define "api.labels" -}}
app.kubernetes.io/name: api
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}
