{{- define "lifecycle-authority.labels" -}}
app.kubernetes.io/name: prodbox-lifecycle-authority
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "lifecycle-authority.selectorLabels" -}}
app.kubernetes.io/name: prodbox-lifecycle-authority
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
