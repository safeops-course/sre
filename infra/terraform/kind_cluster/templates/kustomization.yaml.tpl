apiVersion: kustomize.toolkit.fluxcd.io/v1beta2
kind: Kustomization
metadata:
  name: ${name}
  namespace: flux-system
spec:
  interval: ${interval}
  path: ${path}
  prune: true
  sourceRef:
    kind: GitRepository
    name: ${source}
  timeout: 2m
  wait: true
