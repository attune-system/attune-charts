# Attune site chart

This chart installs the public site and its SMTP-backed inquiry form.

## Install with a pre-created SMTP Secret

Build and import the `attune-site:local` image on each k3s node. Then create the
SMTP Secret in the release namespace:

```bash
kubectl -n attune-sites create secret generic attune-site-smtp \
  --from-literal=host=smtp.example.com \
  --from-literal=from=site@attunedev.org \
  --from-literal=username=SMTP_USERNAME \
  --from-literal=password=SMTP_PASSWORD
```

Install the chart:

```bash
helm upgrade --install attune-site attune/attune-site \
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
        - attunedev.org
      secretName: attunedev-org-tls
```
