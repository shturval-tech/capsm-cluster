Хельм чарт для создания клиентского capsm кластера

# Пример использования

Для использования необходимо заменить файл сертификата conf/auth.crt (root СА сертификата от auth.apps.ingress.management.cluster)
А так же добавить приватный SSH ключ для подключения к узлам в файл conf/stc
Если будет использоваться внешний ETCD, то так же заменить сертификаты для ETCD в conf/ext_etcd-*

После чего добавить хосты в пул CAPSMv2 (правим значения в values файле):
```yaml
...
capsm:
  hosts:
    master:
      address:
        - 10.31.145.100
        - 10.31.145.101
        - 10.31.145.102
    worker:
      address:
        - 10.31.145.110
        - 10.31.145.111
...
```
или определяем значения хостов через ключи helm в команде создания кластера
```bash
--set capsm.hosts.master.address[0]=10.31.145.100 \
--set capsm.hosts.master.address[1]=10.31.145.101 \
--set capsm.hosts.master.address[2]=10.31.145.102
```

и можно создавать кластер:
```bash
helm upgrade --install clustername . \
    --set licensetoken=XXXXXX \
    --set systemregistry=myregistry.domain.tld \
    --set master.replicas=3 \
    --set workerNodes.infra.replicas=1 \
    --set clusterAPI=10.31.145.174 \
    --set ingressVip=10.31.145.175 \
    --set authMgmtIngress="auth.apps.ip-10-31-145-171.shturval.link" \
    --set logsMgmtIngress="logs.apps.ip-10-31-145-175.shturval.link" \
    --set metricsMgmtIngress="vminsert.apps.ip-10-31-145-175.shturval.link" \
    --set ingress="apps.ip-10-31-145-175.shturval.link"
```

Деинсталляция кластера:
```bash
helm uninstall clustername
```

# Типовые сценарии

### Добавить дополнительные узлы в пул кластера
Мы можем добавить дополнительные узлы в пул кластера для того чтобы произвести расширение кластера или произвести редеплой узла. Для этого в values файл в разделе capsm добавляем дополнительные IP адреса узлов к определенной группе узлов:
```yaml
...
capsm:
  hosts:
    master:
      address:
        - 10.31.145.100
        - 10.31.145.101
        - 10.31.145.102
    worker:
      address:
        - 10.31.145.110
        - 10.31.145.111
        - 10.31.145.112 # новый дополнительный узел
        - 10.31.145.113 # новый дополнительный узел
...
```

После этого выполнить helm upgrade как делали при инсталляции кластера.

### Увеличение или уменьшение количества узлов кластера
После того как мы расширили пул кластера мы можем увеличить количество реплик нужной нам группы:
```yaml
...
workerNodes:
  workers:
    replicas: 4 # Увеличили кол-во реплик с 2 до 4 у группы workers
...
```

Далее выполнить helm upgrade как делали при инсталляции кластера. После чего capsm провайдер подготовит свободные узлы и добавит их в кластер.

### Автомасштабирование группы узлов (cluster-autoscaler)
Для группы worker-узлов можно включить автомасштабирование через Cluster API cluster-autoscaler (как в UI/backend Штурвала):

```yaml
workerNodes:
  workers:
    replicas: 2 # минимум и стартовое число узлов
    autoscaling:
      enabled: true
      maxMachines: 6
    hostSelector:
      matchLabels:
        role: worker
```

Что происходит при `autoscaling.enabled: true`:
- на `MachineDeployment` выставляются аннотации min-size=`replicas` и max-size=`maxMachines`;
- `spec.replicas` **не рендерится** (им владеет autoscaler) — иначе `helm template` / helm-diff показывают вечный drift;
- в namespace кластера создаются ServiceAccount, ClusterRoleBinding на `shturval-cluster-autoscaler` и Deployment `{release}-autoscaler` с `--enforce-node-group-min-size`.

Ограничения CAPSM: autoscaler не создаёт новые ВМ — нужны свободные хосты в пуле (`capsm.hosts` / `ShturvalHost`) под `hostSelector` группы. На management-кластере должен быть ClusterRole `shturval-cluster-autoscaler` (ставит платформа вместе с backend).

Для уменьшения количества реплик нет необходимости расширять пул кластера. После уменьшения количества реплик узлы должны будут освободиться и их можно будет оставить в пуле. Если вы планируете удалить узел из пула, то вам необходимо дождаться когда он станет свободным и только после это провести удаление свободного узла из пула. Проверить что узел освободился можно либо через веб интерфейс или просмотрев статус ресурса ShturvalHost:
```yaml
# если узел используется, то будет значение linkedmachine
...
status:
  linkedmachine:
    name: test-cluster-workers-5h7lc-pdkwm
    namespace: test-cluster
...
```

### Удалить свободный узел из пула кластера
После того как узел стал свободным его можно безопасно удалить из пула:
```yaml
...
capsm:
  hosts:
    master:
      address:
        - 10.31.145.100
        - 10.31.145.101
        - 10.31.145.102
    worker:
      address:
        - 10.31.145.110
        - 10.31.145.111
        # - 10.31.145.112 # удаляем свободный узел из пула
...
```

После этого выполнить helm upgrade как делали при инсталляции кластера.

### Произвести замену узла
Чтобы произвести замену узла нам необходим новый свободный узел в пуле кластера. Для этого мы можем добавить дополнительный узел в пул или сразу заменить узел на новый. Для этого в values файле в разделе capsm меняем IP адрес узла в нужной нам группе узлов:
```yaml
...
capsm:
  hosts:
    master:
      address:
        - 10.31.145.100
        - 10.31.145.101
        - 10.31.145.103 # заменяем 10.31.145.102 на новый узлел 10.31.145.103
    worker:
      address:
        - 10.31.145.110
        - 10.31.145.111
...
```

Далее выполнить helm upgrade как делали при инсталляции кластера.
После чего в управляющем кластере удаляем узел (или через cli ресурс Machine) со старым нашим хостом (10.31.145.102) и ждем когда capsm провайдер задеплоит/добавит новый узел (10.31.145.103) в кластер, а старый узел в пуле пометит как свободный.

