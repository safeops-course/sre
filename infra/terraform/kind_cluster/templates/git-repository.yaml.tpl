apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: GitRepository
metadata:
  name: ${name}
  namespace: flux-system
spec:
  interval: ${interval}
  url: ${url}
  ref:
    branch: ${branch}
