{{- define "gateway.labels" -}}
app.kubernetes.io/name: prodbox-gateway
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: prodbox
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

{{- /*
gateway.dhallDouble formats a numeric value as a Dhall `Double` literal. Dhall
distinguishes `Natural` from `Double` strictly, so integer-valued doubles
(`1`, `2`, …) must be written `1.0`, `2.0`, … on the wire. Sprint 2.22 uses
this helper from `configmap-config.yaml` so values like
`timing.syncIntervalSeconds: 1.0` (which YAML normalizes to `1`) still decode
as Dhall `Double` via the in-process `Dhall.inputFile auto` decoder
(Sprint 2.20).
*/ -}}
{{- define "gateway.dhallDouble" -}}
{{- $rendered := printf "%v" . -}}
{{- if contains "." $rendered -}}
{{- $rendered -}}
{{- else -}}
{{- printf "%s.0" $rendered -}}
{{- end -}}
{{- end -}}

{{- /*
gateway.secretRefVault renders the Dhall union value consumed by
Prodbox.Settings.SecretRef. Gateway chart-secret consumers read Vault
directly through Kubernetes auth; no k8s Secret-mounted Dhall fragments are
part of the supported path.
*/ -}}
{{- define "gateway.secretRefVault" -}}
< Vault : { mount : Text, path : Text, field : Text }
| TransitKey : Text
| Prompt : { name : Text, purpose : Text }
| TestPlaintext : Text
>.Vault
  { mount = {{ .mount | quote }}
  , path = {{ .path | quote }}
  , field = {{ .field | quote }}
  }
{{- end -}}
