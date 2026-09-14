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
helm.sh/chart: {{ include "attune.chart" . | quote }}
app.kubernetes.io/name: {{ include "attune.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{- define "attune.selectorLabels" -}}
app.kubernetes.io/name: {{ include "attune.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
{{- end -}}

{{- define "attune.componentLabels" -}}
{{ include "attune.selectorLabels" .root }}
app.kubernetes.io/component: {{ .component | quote }}
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
{{- required "security.existingSecret is required; store runtime credentials in a Kubernetes Secret" .Values.security.existingSecret -}}
{{- end -}}

{{- define "attune.identitySecretName" -}}
{{- if .Values.security.identitySecret.existingSecret -}}
{{- .Values.security.identitySecret.existingSecret -}}
{{- else -}}
{{- printf "%s-identity" (include "attune.fullname" .) -}}
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

{{- define "attune.apiServiceName" -}}
{{- printf "%s-api" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.notifierServiceName" -}}
{{- printf "%s-notifier" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.mcpServiceName" -}}
{{- printf "%s-mcp" (include "attune.fullname" .) -}}
{{- end -}}

{{- define "attune.apiServiceAccountName" -}}
{{- default (printf "%s-api" (include "attune.fullname" .)) .Values.serviceAccounts.api.name -}}
{{- end -}}

{{- define "attune.supervisorServiceAccountName" -}}
{{- default (printf "%s-supervisor" (include "attune.fullname" .)) .Values.serviceAccounts.supervisor.name -}}
{{- end -}}

{{- define "attune.storageMigrationApiServiceAccountName" -}}
{{- if .Values.serviceAccounts.api.create -}}
{{- printf "%s-storage-migration-api" (include "attune.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "attune.apiServiceAccountName" . -}}
{{- end -}}
{{- end -}}

{{- define "attune.storageMigrationSupervisorServiceAccountName" -}}
{{- if .Values.serviceAccounts.supervisor.create -}}
{{- printf "%s-storage-migration-supervisor" (include "attune.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "attune.supervisorServiceAccountName" . -}}
{{- end -}}
{{- end -}}

{{- define "attune.revisionApiServiceName" -}}
{{- $suffix := printf "-api-r%d" .Release.Revision -}}
{{- printf "%s%s" (include "attune.fullname" . | trunc (int (sub 63 (len $suffix))) | trimSuffix "-") $suffix -}}
{{- end -}}

{{- define "attune.previousReleaseUsesObjectStorage" -}}
{{- $configMap := lookup "v1" "ConfigMap" .Release.Namespace (printf "%s-config" (include "attune.fullname" .)) -}}
{{- $configData := get ($configMap | default dict) "data" | default dict -}}
{{- $config := get $configData "config.yaml" | default "" | fromYaml | default dict -}}
{{- $storage := get $config "storage" | default dict -}}
{{- $provider := get $storage "provider" | default "" -}}
{{- if or (eq $provider "s3") (eq $provider "gcs") -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "attune.storageCutoverRequired" -}}
{{- $packs := lookup "v1" "PersistentVolumeClaim" .Release.Namespace (printf "%s-packs" (include "attune.fullname" .)) -}}
{{- $runtimeEnvs := lookup "v1" "PersistentVolumeClaim" .Release.Namespace (printf "%s-runtime-envs" (include "attune.fullname" .)) -}}
{{- $artifacts := lookup "v1" "PersistentVolumeClaim" .Release.Namespace (printf "%s-artifacts" (include "attune.fullname" .)) -}}
{{- $hasLegacyClaims := or $packs $runtimeEnvs $artifacts -}}
{{- $previousObjectMode := eq (include "attune.previousReleaseUsesObjectStorage" .) "true" -}}
{{- if and .Release.IsUpgrade (eq .Values.storage.mode "object") $hasLegacyClaims (not $previousObjectMode) -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{- define "attune.localCacheVolume" -}}
{{- if eq .root.Values.storage.local.mode "genericEphemeralVolume" -}}
ephemeral:
  volumeClaimTemplate:
    spec:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: {{ .volume.sizeLimit | quote }}
      {{- if .volume.storageClassName }}
      storageClassName: {{ .volume.storageClassName | quote }}
      {{- end }}
{{- else -}}
emptyDir:
  sizeLimit: {{ .volume.sizeLimit | quote }}
{{- end }}
{{- end -}}

{{- define "attune.localStoragePodSecurityContext" -}}
securityContext:
  {{- toYaml .Values.storage.local.podSecurityContext | nindent 2 }}
{{- end -}}

{{- define "attune.waitForCorePack" -}}
- name: wait-for-core-pack
  {{- if eq .Values.storage.mode "sharedVolume" }}
  image: busybox:1.36
  command: ["/bin/sh", "-ec"]
  args:
    - |
      until [ -f /opt/attune/packs/.attune-bootstrap-r{{ .Release.Revision }} ]; do
        echo "waiting for current pack bootstrap";
        sleep 2;
      done
  volumeMounts:
    - name: packs
      mountPath: /opt/attune/packs
      readOnly: true
  {{- else }}
  image: {{ include "attune.image" (dict "root" . "image" .Values.images.initPacks) | quote }}
  imagePullPolicy: {{ .Values.images.initPacks.pullPolicy | quote }}
  command: ["python3", "/scripts/bootstrap_core_pack.py", "wait"]
  envFrom:
    - secretRef:
        name: {{ include "attune.secretName" . | quote }}
  env:
    - name: ATTUNE_API_URL
      value: {{ printf "http://%s:%v" (include "attune.apiServiceName" .) .Values.api.service.port | quote }}
  {{- end }}
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
        name: {{ include "attune.secretName" . | quote }}
{{- end -}}

{{- define "attune.waitForRabbitmqCredentials" -}}
- name: wait-for-rabbitmq-credentials
  image: {{ printf "%s:%s" .Values.rabbitmq.provisioning.image.repository .Values.rabbitmq.provisioning.image.tag | quote }}
  imagePullPolicy: {{ .Values.rabbitmq.provisioning.image.pullPolicy | quote }}
  command: ["python3", "-c"]
  args:
    - |
      import os
      import socket
      import struct
      import time

      def read_exact(connection, size):
          data = b""
          while len(data) < size:
              chunk = connection.recv(size - len(data))
              if not chunk:
                  raise ConnectionError("RabbitMQ closed the connection")
              data += chunk
          return data

      def read_frame(connection):
          frame_type, channel, size = struct.unpack(">BHI", read_exact(connection, 7))
          payload = read_exact(connection, size)
          if read_exact(connection, 1) != b"\xce" or frame_type != 1 or channel != 0:
              raise ConnectionError("unexpected AMQP frame")
          return payload

      def method_frame(payload):
          return b"\x01" + struct.pack(">HI", 0, len(payload)) + payload + b"\xce"

      def short_string(value):
          return bytes([len(value)]) + value

      def long_string(value):
          return struct.pack(">I", len(value)) + value

      def authenticate():
          with socket.create_connection(
              (os.environ["RABBITMQ_HOST"], int(os.environ["RABBITMQ_PORT"])),
              timeout=10,
          ) as connection:
              connection.sendall(b"AMQP\x00\x00\x09\x01")
              start = read_frame(connection)
              if struct.unpack(">HH", start[:4]) != (10, 10):
                  raise ConnectionError("RabbitMQ did not send connection.start")

              username = os.environ["RABBITMQ_USER"].encode()
              password = os.environ["RABBITMQ_PASSWORD"].encode()
              response = b"\x00" + username + b"\x00" + password
              start_ok = (
                  struct.pack(">HHI", 10, 11, 0)
                  + short_string(b"PLAIN")
                  + long_string(response)
                  + short_string(b"en_US")
              )
              connection.sendall(method_frame(start_ok))

              tune = read_frame(connection)
              if struct.unpack(">HH", tune[:4]) != (10, 30):
                  raise PermissionError("RabbitMQ rejected the service credentials")
              channel_max, frame_max, heartbeat = struct.unpack(">HIH", tune[4:12])
              tune_ok = struct.pack(
                  ">HHHIH", 10, 31, channel_max, frame_max, heartbeat
              )
              connection.sendall(method_frame(tune_ok))

              connection_open = (
                  struct.pack(">HH", 10, 40)
                  + short_string(b"/")
                  + short_string(b"")
                  + b"\x00"
              )
              connection.sendall(method_frame(connection_open))
              open_ok = read_frame(connection)
              if struct.unpack(">HH", open_ok[:4]) != (10, 41):
                  raise PermissionError("RabbitMQ rejected access to the vhost")

              connection_close = (
                  struct.pack(">HHH", 10, 50, 200)
                  + short_string(b"")
                  + struct.pack(">HH", 0, 0)
              )
              connection.sendall(method_frame(connection_close))
              close_ok = read_frame(connection)
              if struct.unpack(">HH", close_ok[:4]) != (10, 51):
                  raise ConnectionError("RabbitMQ did not close cleanly")

      while True:
          try:
              authenticate()
              break
          except (OSError, struct.error, ValueError):
              print("waiting for provisioned RabbitMQ service account", flush=True)
              time.sleep(2)
  env:
    - name: RABBITMQ_HOST
      value: {{ include "attune.rabbitmqServiceName" . | quote }}
    - name: RABBITMQ_PORT
      value: {{ .Values.rabbitmq.port | quote }}
  envFrom:
    - secretRef:
        name: {{ include "attune.secretName" . | quote }}
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
