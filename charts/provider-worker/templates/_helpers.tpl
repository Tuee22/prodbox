{{- define "provider-worker.labels" -}}
app.kubernetes.io/name: prodbox-provider-worker
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "provider-worker.selectorLabels" -}}
app.kubernetes.io/name: prodbox-provider-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
