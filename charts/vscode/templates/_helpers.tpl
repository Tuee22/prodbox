{{- define "vscode.labels" -}}
app.kubernetes.io/name: vscode
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "vscode.oauth2ProxyLabels" -}}
app.kubernetes.io/name: vscode-auth-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}
