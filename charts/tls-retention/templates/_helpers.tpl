{{- define "tls-retention.labels" -}}
app.kubernetes.io/name: prodbox-tls-retention
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "tls-retention.selectorLabels" -}}
app.kubernetes.io/name: prodbox-tls-retention
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
