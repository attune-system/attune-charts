# Attune documentation site chart

This chart installs the static documentation site.

Install the chart:

```bash
helm upgrade --install attune-docs-site attune/attune-docs-site \
  --namespace attune-sites \
  --create-namespace
```

The chart defaults to the public
`ghcr.io/attune-system/attune-docs-site:0.1.2` image. Set `image.repository`,
`image.tag`, and `imagePullSecrets` to use a private image instead.

## Configure TLS

Add a TLS entry after your certificate controller creates the Secret:

```yaml
ingress:
  tls:
    - hosts:
        - docs.attunedev.org
      secretName: docs-attunedev-org-tls
```
