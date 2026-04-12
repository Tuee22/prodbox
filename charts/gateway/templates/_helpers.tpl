{{- define "gateway.labels" -}}
app.kubernetes.io/name: prodbox-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: Helm
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
{{- end -}}

{{- define "gateway.selectorLabels" -}}
app.kubernetes.io/name: prodbox-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- /*
gateway.podDnsName renders the stable DNS name for one StatefulSet pod ordinal.
The headless service name is hardcoded to "gateway".
*/ -}}
{{- define "gateway.podDnsName" -}}
{{- $ordinal := index . 0 -}}
{{- $namespace := index . 1 -}}
gateway-{{ $ordinal }}.gateway.{{ $namespace }}.svc.cluster.local
{{- end -}}
