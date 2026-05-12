{{- define "vscode.labels" -}}
app.kubernetes.io/name: vscode
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}
