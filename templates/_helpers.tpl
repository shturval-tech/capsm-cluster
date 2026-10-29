{{/*
Expand the name of the chart.
*/}}
{{- define "capsm-cluster.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "capsm-cluster.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capsm-cluster.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capsm-cluster.labels" -}}
helm.sh/chart: {{ include "capsm-cluster.chart" . }}
{{ include "capsm-cluster.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Format node-labels for kubelet, skipping keys that contain forbidden substrings.
Expects a list of "key=value" strings. Returns a comma-separated string.
*/}}
{{- define "capsm-cluster.nodeLabels" -}}
{{- $forbidden := list "kubernetes.io/" "k8s.io/" -}}
{{- $filtered := list -}}
{{- range . -}}
  {{- $key := (splitList "=" . | first) -}}
  {{- $skip := false -}}
  {{- range $forbidden -}}
    {{- if contains . $key -}}
      {{- $skip = true -}}
    {{- end -}}
  {{- end -}}
  {{- if not $skip -}}
    {{- $filtered = append $filtered . -}}
  {{- end -}}
{{- end -}}
{{- join "," $filtered -}}
{{- end -}}

{{/*
Convert a list of "key=value" strings to YAML map entries for metadata labels/annotations.
Values may contain '=' (everything after the first '=' is the value).
*/}}
{{- define "capsm-cluster.kvListToMetadata" -}}
{{- range . }}
{{- $parts := splitList "=" . }}
{{- $key := index $parts 0 }}
{{- $val := "" }}
{{- if gt (len $parts) 1 }}
{{- $val = join "=" (rest $parts) }}
{{- end }}
{{ $key }}: {{ $val | quote }}
{{- end }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "capsm-cluster.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capsm-cluster.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "capsm-cluster.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "capsm-cluster.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the ClusterConfig of the secret to use
*/}}
{{- define "capsm-cluster.clusterConfig" -}}
{{- tpl (.Files.Get .Values.clusterConfigFile) . | b64enc | quote }}
{{- end }}

{{/*
Create the Certificate
*/}}
{{- define "capsm-cluster.authCert" -}}
{{- .Files.Get .Values.authCrtFile | b64enc | quote }}
{{- end }}

{{/*
Create the Certificate for etcd
*/}}
{{- define "capsm-cluster.etcd.caCrt" -}}
{{- if .Values.etcd.external.caCrt }}
{{- .Files.Get .Values.etcd.external.caCrt | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Create the Certificate for etcd
*/}}
{{- define "capsm-cluster.etcd.apiCrt" -}}
{{- if .Values.etcd.external.apiCrt }}
{{- .Files.Get .Values.etcd.external.apiCrt  | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Create the Certificate for etcd
*/}}
{{- define "capsm-cluster.etcd.apiKey" -}}
{{- if .Values.etcd.external.apiKey }}
{{- .Files.Get .Values.etcd.external.apiKey  | b64enc | quote }}
{{- end }}
{{- end }}

{{/*
Shared encryption key for one helm render.
Same contract as backend: Secret.data.secret = raw key.
*/}}
{{- define "capsm-cluster.encryptionKey" -}}
{{- if not .Values._encryptionKey -}}
{{- $key := "" -}}
{{- $secretName := printf "%s-encryption-configuration" .Release.Name -}}
{{- $existing := lookup "v1" "Secret" .Release.Name $secretName -}}
{{- if and $existing $existing.data $existing.data.secret -}}
{{- $key = index $existing.data "secret" | b64dec -}}
{{- else if .Values.etcd.encryptionSeed -}}
{{- $key = sha256sum (printf "%s:%s-encryption-key" (toString .Values.etcd.encryptionSeed) .Release.Name) | trunc 32 -}}
{{- else -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec -}}
{{- /* Апгрейд существующего кластера: ключ не меняем. */ -}}
{{- $key = sha256sum (printf "%s-encryption-key" .Release.Name) | trunc 32 -}}
{{- else -}}
{{- fail (printf "новый кластер %s: задайте etcd.encryptionSeed в values (случайная строка, например `openssl rand -base64 32`). Без seed шифрование etcd не будет безопасным." .Release.Name) -}}
{{- end -}}
{{- end -}}
{{- $_ := set .Values "_encryptionKey" $key -}}
{{- end -}}
{{- .Values._encryptionKey -}}
{{- end -}}

{{/*
Content of /etc/kubernetes/secrets_encryption.yaml
*/}}
{{- define "capsm-cluster.secretsEncryptionContent" -}}
---
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
          - name: key1
            secret: {{ include "capsm-cluster.encryptionKey" . | b64enc }}
    - identity: {}
{{- end -}}

{{/*
Generate nci.json (ShturvalInit) as base64-encoded JSON.
Usage: include "capsm-cluster.nci.json.b64" (dict "ctx" . "controlplane" true)
  controlplane=true  — adds kube-vip (unless external LB), and when secure=true: secrets_encryption, audit_policy
  controlplane=false — directories and system config only (workers)
*/}}
{{- define "capsm-cluster.nci.json.b64" -}}
{{- $ctx := .ctx -}}
{{- $nciCtx := dict
  "Values"       $ctx.Values
  "Files"        $ctx.Files
  "Release"      $ctx.Release
  "Chart"        $ctx.Chart
  "controlplane" .controlplane
-}}
{{- tpl ($ctx.Files.Get "conf/nci.yaml") $nciCtx | fromYaml | toJson | b64enc -}}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capsm-cluster.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

{{- define "capsm-cluster.sshKey" -}}
{{- if .Values.capsm.sshKeyPath }}
{{- .Files.Get .Values.capsm.sshKeyPath | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "capsm-cluster.kubeadmPatchesEffective" -}}
{{- $kp := dict -}}
{{- range $k, $v := (.Values.kubeadmPatches | default dict) }}
{{- $_ := set $kp $k $v -}}
{{- end }}
{{- range $k, $v := (.Values.patch | default dict) }}
{{- if not (hasKey $kp $k) }}
{{- $_ := set $kp $k $v -}}
{{- end }}
{{- end }}
{{- $dir := index $kp "directory" | default "" -}}
{{- if not $dir }}
{{- $has := false -}}
{{- range $k, $v := $kp }}
{{- if and (kindIs "map" $v) $v.patchTemplate }}
{{- $has = true -}}
{{- end }}
{{- end }}
{{- if $has }}
{{- $_ := set $kp "directory" "/etc/kubernetes/manifests-pathes" -}}
{{- end }}
{{- end }}
{{- toYaml $kp -}}
{{- end -}}

{{/*
Filename for a kubeadm patch in kubeadmPatches.directory.
*/}}
{{- define "capsm-cluster.kubeadmPatchFilename" -}}
{{- $name := .name -}}
{{- $patch := .patch | default dict -}}
{{- if $patch.filename -}}
{{- $patch.filename -}}
{{- else if eq $name "kubeapi" -}}
kube-apiserver.yaml
{{- else -}}
{{- printf "%s.yaml" $name -}}
{{- end -}}
{{- end -}}

{{- define "capsm-cluster.vipInterface" -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- $kv := $ni.kubevip | default dict -}}
{{- if $kv.interface -}}
{{- $kv.interface -}}
{{- else -}}
{{- (.Values.capsm | default dict).vipInterface | default "eth0" -}}
{{- end -}}
{{- end -}}

{{- define "capsm-cluster.patchResources" -}}
{{- $kp := .root.Values.kubeadmPatches | default dict -}}
{{- $legacy := .root.Values.patch | default dict -}}
{{- $p := dict -}}
{{- if hasKey $kp .name -}}
{{- $p = index $kp .name | default dict -}}
{{- else if hasKey $legacy .name -}}
{{- $p = index $legacy .name | default dict -}}
{{- end -}}
{{- toYaml $p.resources -}}
{{- end -}}

{{- define "capsm-cluster.patch.kube-apiserver" -}}
{{- $kp := include "capsm-cluster.kubeadmPatchesEffective" . | fromYaml -}}
{{- $p := index $kp "kubeapi" | default dict -}}
{{- if $p.patchTemplate }}
{{- tpl (.Files.Get $p.patchTemplate) . | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "capsm-cluster.patch.etcd" -}}
{{- $kp := include "capsm-cluster.kubeadmPatchesEffective" . | fromYaml -}}
{{- $p := index $kp "etcd" | default dict -}}
{{- if $p.patchTemplate }}
{{- tpl (.Files.Get $p.patchTemplate) . | b64enc | quote }}
{{- end }}
{{- end }}

{{- define "capsm-cluster.capsm.hosts" -}}
  {{- if .Values.capsm }}{{ if .Values.capsm.hosts }}
    {{- range $k, $v := .Values.capsm.hosts }}
        {{- range $k2, $v2 := $v.address }}
        {{- printf "- address: %s" $v2 | nindent 0}}
        {{- printf "labels:" | nindent 2 }}
        {{- printf "role: %s" $k | nindent 4 }}
        {{- printf "provider_config_name: %s" $.Release.Name | nindent 4 }}
        {{- if $v.labels }}
          {{- toYaml $v.labels | nindent 4 }}
        {{- end }}
        {{- end }}
    {{- end }}
  {{- end }}{{ end }}
{{- end }}

{{/*
CAPSM profile name
*/}}
{{- define "capsm-cluster.capsm.profileName" -}}
{{- default .Release.Name .Values.capsm.profileName }}
{{- end }}

{{/*
CAPSM kubelet default
*/}}
{{- define "capsm-cluster.kubelet" -}}
serverTLSBootstrap: true # default false
protectKernelDefaults: true # default false
# kubeReserved: # default nil
#   ephemeral-storage: "1024Mi"
# systemReserved: # default nil
#   cpu: "200m"
#   memory: "600Mi"
# maxPods: 115 # default 110
# evictionHard: {memory.available: "128Mi", nodefs.available: "10%", nodefs.inodesFree: "6%", imagefs.available: "10%"} # default: memory.available: "100Mi" nodefs.available: "10%" nodefs.inodesFree: "5%" imagefs.available: "15%"
# evictionSoft: {memory.available: "256Mi", nodefs.available: "15%", nodefs.inodesFree: "10%", imagefs.available: "15%"} # default: nil
# evictionSoftGracePeriod: {memory.available: "1m30s", nodefs.available: "1m30s", nodefs.inodesFree: "1m30s", imagefs.available: "1m30s"} # default: nil
# allowedUnsafeSysctls: # default []
#   - net.core.somaxconn
# registryPullQPS: 5 # default 5
# registryBurst: 10 # default 10
# runtimeRequestTimeout: "15m" # default "2m"
# imageMinimumGCAge: "120h" # default "2m"
# enforceNodeAllocatable: ["pods"] # default: ["pods"]
# memorySwap:
#   swapBehavior: NoSwap # default: NoSwap
# kubeAPIQPS: 50 # default 50
# kubeAPIBurst: 100 # default 100
# eventRecordQPS: 50 # default 50
# eventBurst: 100 # default 100
# serializeImagePulls: false # default true
# maxParallelImagePulls: 15 # default nil
{{- end }}

{{/*
Default system image repository name (containerd certs.d / runtimecfg.registries.name).
Not user-configurable — always r.shturval.tech as in platform bootstrap.
*/}}
{{- define "capsm-cluster.defaultSystemRepo" -}}
r.shturval.tech
{{- end -}}

{{/*
Copy extraArgs into .out.
items is a map name->value or a list of {name, value}.
Same name overwrites. Callers render the dict sorted by name.
*/}}
{{- define "capsm-cluster.extraArgs.absorb" -}}
{{- $out := .out -}}
{{- $items := .items -}}
{{- if kindIs "map" $items -}}
{{- range $k, $v := $items -}}
{{- $_ := set $out ($k | toString) ($v | toString) -}}
{{- end -}}
{{- else if or (kindIs "slice" $items) (kindIs "array" $items) -}}
{{- range $item := $items -}}
{{- if and (kindIs "map" $item) (index $item "name") -}}
{{- $val := "" -}}
{{- if hasKey $item "value" -}}
{{- $val = index $item "value" | toString -}}
{{- end -}}
{{- $_ := set $out (index $item "name" | toString) $val -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Render extraArgs as a list sorted by name.
Input: dict "items" (name->value), "root" (chart context for tpl).
*/}}
{{- define "capsm-cluster.extraArgs.render" -}}
{{- $items := .items -}}
{{- $root := .root -}}
{{- range $name := (keys $items | sortAlpha) }}
- name: {{ $name }}
  value: {{ tpl (index $items $name) $root | quote }}
{{- end -}}
{{- end -}}

{{/*
CAPSM apiserver default.
Audit/encryption args only when secure=true.
Values apiServer.extraArgs (map or list) overlay these by name; the list is always sorted.
*/}}
{{- define "capsm-cluster.apiserver" -}}
{{- $args := dict
  "authorization-mode" "Node,RBAC"
  "default-not-ready-toleration-seconds" "30"
  "default-unreachable-toleration-seconds" "30"
  "kubelet-certificate-authority" "/etc/kubernetes/pki/ca.crt"
  "oidc-ca-file" "/etc/ssl/certs/oidc.crt"
  "oidc-client-id" "backend"
  "oidc-groups-claim" "claims"
  "oidc-groups-prefix" "shturval:"
  "oidc-issuer-url" (printf "https://%s" .Values.authMgmtIngress)
  "oidc-username-claim" "sub"
  "oidc-username-prefix" "shturval:"
  "profiling" "false"
  "request-timeout" "60s"
  "tls-min-version" "VersionTLS13"
-}}
{{- if .Values.secure -}}
{{- $_ := set $args "audit-log-maxage" "30" -}}
{{- $_ := set $args "audit-log-maxbackup" "10" -}}
{{- $_ := set $args "audit-log-maxsize" "100" -}}
{{- $_ := set $args "audit-log-mode" "batch" -}}
{{- $_ := set $args "audit-log-path" "/var/log/kube-api-audit/audit.log" -}}
{{- $_ := set $args "audit-policy-file" (.Values.auditPolicy.location | toString) -}}
{{- $_ := set $args "encryption-provider-config" "/etc/kubernetes/secrets_encryption.yaml" -}}
{{- end -}}
{{- if and .Values.apiServer .Values.apiServer.extraArgs -}}
{{- include "capsm-cluster.extraArgs.absorb" (dict "out" $args "items" .Values.apiServer.extraArgs) -}}
{{- end -}}
extraArgs:
{{- include "capsm-cluster.extraArgs.render" (dict "items" $args "root" .) | trim | nindent 0 }}
{{- end }}

{{/*
CAPSM controllerManager default.
Values controllerManager.extraArgs overlay by name; the list is always sorted.
*/}}
{{- define "capsm-cluster.controllerManager" -}}
{{- $args := dict
  "bind-address" "0.0.0.0"
  "node-monitor-grace-period" "20s"
  "node-monitor-period" "2s"
  "profiling" "false"
  "terminated-pod-gc-threshold" "10"
  "tls-min-version" "VersionTLS13"
-}}
{{- if and .Values.controllerManager .Values.controllerManager.extraArgs -}}
{{- include "capsm-cluster.extraArgs.absorb" (dict "out" $args "items" .Values.controllerManager.extraArgs) -}}
{{- end -}}
controllerManager:
  extraArgs:
{{- include "capsm-cluster.extraArgs.render" (dict "items" $args "root" .) | trim | nindent 2 }}
{{- end }}

{{/*
CAPSM scheduler default.
Values scheduler.extraArgs overlay by name; the list is always sorted.
*/}}
{{- define "capsm-cluster.scheduler" -}}
{{- $args := dict
  "bind-address" "0.0.0.0"
  "profiling" "false"
-}}
{{- if and .Values.scheduler .Values.scheduler.extraArgs -}}
{{- include "capsm-cluster.extraArgs.absorb" (dict "out" $args "items" .Values.scheduler.extraArgs) -}}
{{- end -}}
scheduler:
  extraArgs:
{{- include "capsm-cluster.extraArgs.render" (dict "items" $args "root" .) | trim | nindent 2 }}
{{- end }}

{{/*
Convert ASCII to dec
Example: {{- include "capsm-cluster.asciiToDec" (list "conf/auth.crt" .) | nindent 4 }}
*/}}
{{- define "capsm-cluster.asciiToDec" -}}
{{- $args := . -}}
{{- $filePath := index $args 0 -}}
{{- $root := index $args 1 -}}
{{- $content := $root.Files.Get $filePath -}}
{{- range $ch := splitList "" $content -}}
- {{ printf "%d\n" (index $ch 0) }}
{{- end -}}
{{- end -}}

{{/*
True if any workerNodes group has autoscaling.enabled.
*/}}
{{- define "capsm-cluster.autoscalingEnabled" -}}
{{- $enabled := false -}}
{{- range $k, $v := .Values.workerNodes -}}
{{- if and $v.autoscaling $v.autoscaling.enabled -}}
{{- $enabled = true -}}
{{- end -}}
{{- end -}}
{{- $enabled -}}
{{- end -}}

{{/*
Resolve scale params for a worker MachineDeployment group.
Input: dict "root" $ "name" <groupKey> "group" <groupValues>
Output (YAML): enabled, minSize, maxMachines (if enabled), replicas

При autoscaling.enabled чарт не выставляет MachineDeployment.spec.replicas
(см. machinedeployment.yaml) — иначе helm template / helm-diff всегда
показывают drift относительно живого значения, которым владеет cluster-autoscaler.
replicas из values при этом остаётся min-size (пол автоскейлера);
фактический размер группы догоняет autoscaler (--enforce-node-group-min-size).
*/}}
{{- define "capsm-cluster.workerGroupScale" -}}
{{- $name := .name -}}
{{- $group := .group -}}
{{- $autoscaling := $group.autoscaling | default dict -}}
{{- $enabled := $autoscaling.enabled | default false -}}
{{- $minSize := $group.replicas -}}
{{- $replicas := $group.replicas -}}
{{- if $enabled -}}
{{- $_ := required (printf "workerNodes.%s.replicas is required when autoscaling.enabled" $name) $group.replicas -}}
{{- $_ := required (printf "workerNodes.%s.autoscaling.maxMachines is required when autoscaling.enabled" $name) $autoscaling.maxMachines -}}
{{- if gt (int $minSize) (int $autoscaling.maxMachines) -}}
{{- fail (printf "workerNodes.%s.replicas (%v) must be <= autoscaling.maxMachines (%v)" $name $minSize $autoscaling.maxMachines) -}}
{{- end -}}
{{- end -}}
enabled: {{ $enabled }}
minSize: {{ $minSize }}
{{- if $enabled }}
maxMachines: {{ $autoscaling.maxMachines }}
{{- end }}
replicas: {{ $replicas }}
{{- end -}}

{{/*
cluster-autoscaler image.
Тег из профиля релиза, не из kubeVersion: 2.15.0 — v1.36.1-325745, 2.14.x — v1.35.1.
Реестр — systemregistry. Полный образ переопределяется images.clusterAutoscaler.
*/}}
{{- define "capsm-cluster.clusterAutoscalerImage" -}}
{{- if and .Values.images .Values.images.clusterAutoscaler -}}
{{- .Values.images.clusterAutoscaler -}}
{{- else -}}
{{- $p := include "capsm-cluster.releaseProfile" . | fromYaml -}}
{{- $tag := $p.clusterAutoscalerTag | default (printf "v%s" (include "capsm-cluster.effectiveKubeVersion" .)) -}}
{{- printf "%s/autoscaling/cluster-autoscaler:%s" .Values.systemregistry $tag -}}
{{- end -}}
{{- end -}}

{{/*
kube-vip image for NCI.
images.kubeVip, иначе conf/releases, иначе nodeInit.kubevip.image.
*/}}
{{- define "capsm-cluster.kubeVipImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.kubeVip -}}
{{- $images.kubeVip -}}
{{- else -}}
{{- $p := include "capsm-cluster.releaseProfile" . | fromYaml -}}
{{- if $p.kubeVipImage -}}
{{- $p.kubeVipImage -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- $kv := $ni.kubevip | default dict -}}
{{- required "images.kubeVip (или профиль релиза, или nodeInit.kubevip.image) is required" $kv.image -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
pause image for NCI.
images.pause, иначе conf/releases, иначе nodeInit.pauseImage.
*/}}
{{- define "capsm-cluster.pauseImage" -}}
{{- $images := .Values.images | default dict -}}
{{- if $images.pause -}}
{{- $images.pause -}}
{{- else -}}
{{- $p := include "capsm-cluster.releaseProfile" . | fromYaml -}}
{{- if $p.pauseImage -}}
{{- $p.pauseImage -}}
{{- else -}}
{{- $ni := .Values.nodeInit | default dict -}}
{{- required "images.pause (или профиль релиза, или nodeInit.pauseImage) is required" $ni.pauseImage -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Профиль релиза: conf/releases/<shturvalReleaseVersion>.yaml.
Явные values важнее. Профиль нужен для полей, которых не было в 2.14 (CoreDNS),
и как запасной источник, если kubeVersion пустой.
*/}}
{{- define "capsm-cluster.releaseProfile" -}}
{{- $ver := .Values.shturvalReleaseVersion | default "2.15.0" -}}
{{- $path := printf "conf/releases/%s.yaml" $ver -}}
{{- $raw := .Files.Get $path -}}
{{- if not $raw -}}
{{- fail (printf "нет профиля релиза %s (%s). Ожидаются 2.14.0, 2.14.1 или 2.15.0" $ver $path) -}}
{{- end -}}
{{- $raw -}}
{{- end -}}

{{- define "capsm-cluster.effectiveKubeVersion" -}}
{{- if .Values.kubeVersion -}}
{{- .Values.kubeVersion -}}
{{- else -}}
{{- (include "capsm-cluster.releaseProfile" . | fromYaml).kubeVersion -}}
{{- end -}}
{{- end -}}

{{/*
Тег CoreDNS. Пустая строка для 2.14.x — блок dns в KubeadmControlPlane не пишется.
Переопределение: images.coreDNS.
*/}}
{{- define "capsm-cluster.coreDNSTag" -}}
{{- if and .Values.images (index .Values.images "coreDNS") -}}
{{- index .Values.images "coreDNS" -}}
{{- else -}}
{{- $p := include "capsm-cluster.releaseProfile" . | fromYaml -}}
{{- $p.coreDNSImageTag | default "" -}}
{{- end -}}
{{- end -}}

{{/*
Тег etcd. Явный etcd.local.imageTag важнее профиля релиза.
*/}}
{{- define "capsm-cluster.etcdImageTag" -}}
{{- $local := .Values.etcd.local | default dict -}}
{{- if $local.imageTag -}}
{{- $local.imageTag -}}
{{- else -}}
{{- $p := include "capsm-cluster.releaseProfile" . | fromYaml -}}
{{- required "etcd.local.imageTag (или etcdImageTag в профиле релиза) is required" $p.etcdImageTag -}}
{{- end -}}
{{- end -}}

{{/*
Списки сервисов.
Если ClusterConfig уже есть — берём списки из него (webhook запрещает правку).
Иначе values и, для controllerType=gateway, та же нормализация, что ApplyIngressControllerServiceLists.
*/}}
{{- define "capsm-cluster.serviceLists" -}}
{{- $enabled := .Values.services.enabledservices | default (list) -}}
{{- $disabled := .Values.services.disablesservices | default (list) -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.systemServicesConfig -}}
{{- $ssc := $cc.spec.systemServicesConfig -}}
{{- if hasKey $ssc "enabledServices" -}}
{{- $enabled = $ssc.enabledServices | default (list) -}}
{{- end -}}
{{- if hasKey $ssc "disabledServices" -}}
{{- $disabled = $ssc.disabledServices | default (list) -}}
{{- end -}}
{{- else -}}
{{- $gateway := eq (.Values.ingressControllerType | default "nginx") "gateway" -}}
{{- $install := "shturval-ingress-controller" -}}
{{- $remove := "shturval-gateway-api-crds" -}}
{{- if $gateway -}}
{{- $install = "shturval-gateway-api-crds" -}}
{{- $remove = "shturval-ingress-controller" -}}
{{- end -}}
{{- $newEnabled := list -}}
{{- $hasInstall := false -}}
{{- range $enabled -}}
{{- if ne . $remove -}}
{{- $newEnabled = append $newEnabled . -}}
{{- if eq . $install }}{{- $hasInstall = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if not $hasInstall -}}
{{- $newEnabled = append $newEnabled $install -}}
{{- end -}}
{{- $enabled = $newEnabled -}}
{{- $newDisabled := list -}}
{{- $hasRemove := false -}}
{{- range $disabled -}}
{{- if ne . $install -}}
{{- $newDisabled = append $newDisabled . -}}
{{- if eq . $remove }}{{- $hasRemove = true }}{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $gateway (not $hasRemove) -}}
{{- $newDisabled = append $newDisabled $remove -}}
{{- end -}}
{{- $disabled = $newDisabled -}}
{{- end -}}
enabled:
{{ toYaml $enabled | nindent 2 }}
disabled:
{{ toYaml $disabled | nindent 2 }}
{{- end -}}

{{- define "capsm-cluster.validateIngressCerts" -}}
{{- $n := 0 -}}
{{- if .Values.ingressCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.caCert }}{{- $n = add $n 1 }}{{- end -}}
{{- if .Values.acme }}
{{- if or .Values.acme.serverURL .Values.acme.rootCA .Values.acme.rootCABundle .Values.acme.email }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if .Values.vault }}
{{- if or .Values.vault.server .Values.vault.path .Values.vault.token .Values.vault.caBundle .Values.vault.rootCA }}
{{- $n = add $n 1 }}
{{- end }}
{{- end -}}
{{- if gt (int $n) 1 -}}
{{- fail "укажите только один способ сертификата ingress: ingressCert, caCert, acme или vault" -}}
{{- end -}}
{{- $ct := .Values.ingressControllerType | default "nginx" -}}
{{- if not (or (eq $ct "nginx") (eq $ct "gateway")) -}}
{{- fail "ingressControllerType должен быть nginx или gateway" -}}
{{- end -}}
{{- if and .Values.update .Values.update.strategy -}}
{{- if not (or (eq .Values.update.strategy "InPlace") (eq .Values.update.strategy "RollingUpdate")) -}}
{{- fail "update.strategy должен быть InPlace или RollingUpdate" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capsm-cluster.assertCompatibleUpgrade" -}}
{{- $cc := lookup "cluster.shturval.tech/v1beta1" "ClusterConfig" .Release.Name .Release.Name -}}
{{- if and $cc $cc.spec $cc.spec.releaseVersion -}}
{{- $live := $cc.spec.releaseVersion | toString -}}
{{- $want := .Values.shturvalReleaseVersion | toString -}}
{{- if and $live (ne $live $want) (not .Values.platformUpgrade) -}}
{{- fail (printf "ClusterConfig %s уже имеет spec.releaseVersion=%s, в values указано %s. Смена версии запускает обновление платформы. Чтобы обновить только чарт, оставьте shturvalReleaseVersion=%s. Чтобы обновить платформу, задайте platformUpgrade=true. При helm template и в Argo CD lookup пустой, проверка не срабатывает — сверяйте values с живым ClusterConfig до apply." .Release.Name $live $want $live) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "capsm-cluster.preflight" -}}
{{- include "capsm-cluster.validateIngressCerts" . -}}
{{- include "capsm-cluster.assertCompatibleUpgrade" . -}}
{{- end -}}
