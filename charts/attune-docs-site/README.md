# Attune documentation site chart

This chart installs the static documentation site.

Install the chart:

```bash
helm upgrade --install attune-docs-site attune/attune-docs-site \
  --namespace attune-sites \
  --create-namespace
```

The chart defaults to the public
`ghcr.io/attune-system/attune-docs-site:0.1.15` image. Set `image.repository`,
`image.tag`, and `imagePullSecrets` to use a private image instead.

## Change the Slack invite

Set the invite in your values file:

```yaml
slackInviteUrl: "https://join.slack.com/t/attune-dev/shared_invite/YOUR_INVITE"
```

Apply it to the existing release:

```bash
helm upgrade --install attune-docs-site attune/attune-docs-site \
  --namespace attune-sites \
  --values values.yaml \
  --wait
```

The chart sets `SLACK_INVITE_URL` in the pod environment. The values change
rolls the pods without changing their image. `/community/slack/` returns an
uncached temporary redirect to the invite. An empty value uses the static
fallback packaged in the image.

Runtime redirect support requires image version `0.1.12` or later.
Older images do not read `SLACK_INVITE_URL`.

## Configure TLS

Add a TLS entry after your certificate controller creates the Secret:

```yaml
ingress:
  tls:
    - hosts:
        - docs.attunedev.org
      secretName: docs-attunedev-org-tls
```
