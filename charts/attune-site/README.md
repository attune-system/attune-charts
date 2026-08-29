# Attune site chart

This chart installs the public site and its SMTP-backed inquiry form.

## Install with a pre-created SMTP Secret

Create the SMTP Secret in the release namespace:

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

The chart defaults to the public
`ghcr.io/attune-system/attune-site:0.1.1` image. Set `image.repository`,
`image.tag`, and `imagePullSecrets` to use a private image instead.

## Configure TLS

Add a TLS entry after your certificate controller creates the Secret:

```yaml
ingress:
  tls:
    - hosts:
        - attunedev.org
      secretName: attunedev-org-tls
```
