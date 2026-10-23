{{/* Shared by every child Application. Retry, not sync waves, absorbs CRD
ordering; server-side apply avoids the oversized-CRD annotation limit. */}}
{{- define "apps.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ServerSideApply=true
    - SkipDryRunOnMissingResource=true
  retry:
    limit: 10
    backoff:
      duration: 30s
      factor: 2
      maxDuration: 5m
  {{- with .namespaceLabels }}
  managedNamespaceMetadata:
    labels: {{- toYaml . | nindent 6 }}
  {{- end }}
{{- end }}

{{- define "apps.metadata" -}}
metadata:
  name: {{ . }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io # deleting the app deletes what it created
{{- end }}

{{- define "apps.required" -}}
{{- required (printf "%s is empty: run make gitops-env" .key) .value -}}
{{- end }}
