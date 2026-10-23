{{- define "lab-commit.labels" -}}
app.kubernetes.io/name: {{ .name }}
app.kubernetes.io/part-of: lab-commit
{{- end }}

{{/* Image reference: <registry>/<repository>:<tag>, registry optional (kind). */}}
{{- define "lab-commit.image" -}}
{{- with .registry }}{{ . }}/{{ end }}{{ .image.repository }}:{{ required (printf "%s image tag is required" .name) .image.tag }}
{{- end }}

{{/* Restricted Pod Security Standard. */}}
{{- define "lab-commit.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end }}

{{- define "lab-commit.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end }}
