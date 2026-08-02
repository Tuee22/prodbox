{{- define "credential-provisioner.name" -}}
{{- if eq .Values.ingressSchema "external-acme-eab" -}}
external-material-ingress
{{- else if eq .Values.ingressSchema "aws-admin" -}}
credential-provisioner
{{- else -}}
{{- fail "ingressSchema must be aws-admin or external-acme-eab" -}}
{{- end -}}
{{- end -}}

{{- define "credential-provisioner.jobName" -}}
{{- printf "%s-%s" (include "credential-provisioner.name" .) (.Values.permit.id | lower | replace ":" "-" | replace "/" "-" | replace "_" "-" | replace "." "-" | trunc 32 | trimSuffix "-") -}}
{{- end -}}

{{- define "credential-provisioner.serviceAccount" -}}
{{- if eq .Values.ingressSchema "external-acme-eab" -}}
prodbox-external-material-ingress
{{- else if eq .Values.ingressSchema "aws-admin" -}}
prodbox-credential-provisioner
{{- else -}}
{{- fail "ingressSchema must be aws-admin or external-acme-eab" -}}
{{- end -}}
{{- end -}}

{{- define "credential-provisioner.labels" -}}
app.kubernetes.io/name: prodbox-{{ include "credential-provisioner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
prodbox.io/chart-root: {{ .Values.global.rootChart | quote }}
prodbox.io/ingress-schema: {{ .Values.ingressSchema | quote }}
prodbox.io/permit-id: {{ .Values.permit.id | quote }}
{{- end -}}
