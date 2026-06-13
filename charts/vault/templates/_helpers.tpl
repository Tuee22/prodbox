{{- define "vault.labels" -}}
app.kubernetes.io/name: prodbox-vault
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "vault.selectorLabels" -}}
app.kubernetes.io/name: prodbox-vault
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
