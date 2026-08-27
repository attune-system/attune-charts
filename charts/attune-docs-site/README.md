# Attune documentation site chart

This chart installs the static documentation site.

Build and import the `attune-docs-site:local` image on each k3s node. Then
install the chart:

```bash
helm upgrade --install attune-docs-site attune/attune-docs-site \
  --namespace attune-sites \
  --create-namespace
```

For a registry image, set `image.repository` and `image.tag`. Set
`imagePullSecrets` when the registry requires authentication.

## Configure TLS

Add a TLS entry after your certificate controller creates the Secret:

```yaml
ingress:
  tls:
    - hosts:
        - docs.attunedev.org
      secretName: docs-attunedev-org-tls
```
