{{- define "authority-backup.labels" -}}
app.kubernetes.io/name: prodbox-authority-backup
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "authority-backup.selectorLabels" -}}
app.kubernetes.io/name: prodbox-authority-backup
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
