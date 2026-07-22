{{- define "bootstrap-broker.labels" -}}
app.kubernetes.io/name: prodbox-bootstrap-broker
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "bootstrap-broker.selectorLabels" -}}
app.kubernetes.io/name: prodbox-bootstrap-broker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
