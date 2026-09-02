{{- define "attune.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "attune.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name (include "attune.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "attune.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" -}}
{{- end -}}

{{- define "attune.labels" -}}
helm.sh/chart: {{ include "attune.chart" . }}
app.kubernetes.io/name: {{ include "attune.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "attune.selectorLabels" -}}
app.kubernetes.io/name: {{ include "attune.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "attune.componentLabels" -}}
{{ include "attune.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "attune.image" -}}
{{- $root := .root -}}
{{- $image := .image -}}
{{- $registry := $root.Values.global.imageRegistry -}}
{{- $namespace := $root.Values.global.imageNamespace -}}
{{- $repository := $image.repository -}}
{{- $tag := default $root.Values.global.imageTag $image.tag -}}
{{- if and $registry $namespace -}}
{{- printf "%s/%s/%s:%s" $registry $namespace $repository $tag -}}
{{- else if $registry -}}
{{- printf "%s/%s:%s" $registry $repository $tag -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end -}}

{{- define "attune.secretName" -}}
{{- if .Values.security.existingSecret -}}
{{- .Values.security.existingSecret -}}
{{- else -}}
{{- printf "%s-secrets" (include "attune.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "attune.postgresqlAdminSecretName" -}}
{{- if .Values.database.postgresql.admin.existingSecret -}}
{{- .Values.database.postgresql.admin.existingSecret -}}
{{- else -}}
{{- include "attune.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "attune.rabbitmqAdminSecretName" -}}
{{- if .Values.rabbitmq.admin.existingSecret -}}
{{- .Values.rabbitmq.admin.existingSecret -}}
{{- else -}}
{{- include "attune.secretName" . -}}
{{- end -}}
{{- end -}}

{{- define "attune.postgresqlServiceName" -}}
{{- if .Values.database.host -}}
{{- .Values.database.host -}}
{{- else if .Values.database.postgresql.enabled -}}
{{- printf "%s-postgresql" (include "attune.fullname" .) -}}
{{- else -}}
{{- fail "database.host is required when database.postgresql.enabled is false" -}}
{{- end -}}
{{- end -}}

{{- define "attune.rabbitmqServiceName" -}}
{{- if .Values.rabbitmq.host -}}
{{- .Values.rabbitmq.host -}}
{{- else if .Values.rabbitmq.enabled -}}
{{- printf "%s-rabbitmq" (include "attune.fullname" .) -}}
{{- else -}}
{{- fail "rabbitmq.host is required when rabbitmq.enabled is false" -}}
{{- end -}}
{{- end -}}

{{- define "attune.databaseUrl" -}}
{{- if .Values.database.url -}}
{{- .Values.database.url -}}
{{- else -}}
{{- printf "postgresql://%s:%s@%s:%v/%s" (.Values.database.username | urlquery) (.Values.database.password | urlquery) (include "attune.postgresqlServiceName" .) .Values.database.port (.Values.database.database | urlquery) -}}
{{- end -}}
{{- end -}}

{{- define "attune.rabbitmqUrl" -}}
{{- if .Values.rabbitmq.url -}}
{{- .Values.rabbitmq.url -}}
{{- else -}}
{{- printf "amqp://%s:%s@%s:%v" (.Values.rabbitmq.username | urlquery) (.Values.rabbitmq.password | urlquery) (include "attune.rabbitmqServiceName" .) .Values.rabbitmq.port -}}
{{- end -}}
{{- end -}}

{{- define "attune.apiServiceName" -}}
{{- printf "%s-api" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.notifierServiceName" -}}
{{- printf "%s-notifier" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.mcpServiceName" -}}
{{- printf "%s-mcp" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.waitForDatabaseCredentials" -}}
- name: wait-for-database-credentials
  image: postgres:16-alpine
  command: ["/bin/sh", "-ec"]
  args:
    - |
      until PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc 'SELECT 1' >/dev/null 2>&1; do
        echo "waiting for provisioned PostgreSQL service account"
        sleep 2
      done
  envFrom:
    - secretRef:
        name: {{ include "attune.secretName" . }}
{{- end -}}

{{- define "attune.waitForRabbitmqCredentials" -}}
- name: wait-for-rabbitmq-credentials
  image: "{{ .Values.rabbitmq.provisioning.image.repository }}:{{ .Values.rabbitmq.provisioning.image.tag }}"
  imagePullPolicy: {{ .Values.rabbitmq.provisioning.image.pullPolicy }}
  command: ["python3", "-c"]
  args:
    - |
      import base64
      import os
      import time
      import urllib.error
      import urllib.request

      url = "http://{{ include "attune.rabbitmqServiceName" . }}:{{ .Values.rabbitmq.managementPort }}/api/whoami"
      while True:
          token = base64.b64encode(
              f"{os.environ['RABBITMQ_USER']}:{os.environ['RABBITMQ_PASSWORD']}".encode()
          ).decode()
          request = urllib.request.Request(url, headers={"Authorization": f"Basic {token}"})
          try:
              with urllib.request.urlopen(request, timeout=10):
                  break
          except (OSError, urllib.error.HTTPError):
              print("waiting for provisioned RabbitMQ service account", flush=True)
              time.sleep(2)
  envFrom:
    - secretRef:
        name: {{ include "attune.secretName" . }}
{{- end -}}

{{- define "attune.waitForRabbitmqPort" -}}
- name: wait-for-rabbitmq
  image: busybox:1.36
  command: ["/bin/sh", "-ec"]
  args:
    - |
      until nc -z {{ include "attune.rabbitmqServiceName" . }} {{ .Values.rabbitmq.port }}; do
        echo "waiting for RabbitMQ"
        sleep 2
      done
{{- end -}}
