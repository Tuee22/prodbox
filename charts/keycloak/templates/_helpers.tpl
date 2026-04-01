{{- define "keycloak.labels" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}
