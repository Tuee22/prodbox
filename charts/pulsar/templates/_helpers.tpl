{{- define "pulsar.labels" -}}
app.kubernetes.io/name: pulsar
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "pulsar.selectorLabels" -}}
app.kubernetes.io/name: pulsar
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
