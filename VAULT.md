# Vault + External Secrets Operator: домашняя лаборатория

Инструкция для существующего minikube: context `ytd`, три ноды, Docker Desktop
на MacBook. Команды выполняй из корня проекта. Основной nginx, Gateway,
Compose-прокси и Deployment shoplist менять не нужно.

```text
Vault: KV v2 secret/shoplist
  → ESO получает короткоживущий токен через Kubernetes ServiceAccount
  → Secret ytd/shoplist-credentials
  → envFrom в Deployment shoplist
```

Это отдельный, необязательный вариант управления секретами. Файлы `vault/`
не включены в корневой `kustomization.yaml`; обычный `kubectl apply -k .`
не устанавливает Vault или ESO. До выполнения шагов ничего не развёрнуто.
ESO создаёт обычный Kubernetes Secret: значения по-прежнему будут в etcd.

## 1. Настройки лаборатории и предварительная проверка

Здесь один Vault с file storage на PVC, ручной unseal и без HA, не dev-режим.
Для простоты транспорт внутри кластера — HTTP. Это сознательное упрощение
домашней лаборатории, не production best practice: данные и токены могут быть
перехвачены при компрометации сети. Не используй настоящие production-креды.
Vault не публикуется через NodePort, Gateway или домашний reverse proxy.

Проверь инструменты и профиль:

```sh
minikube start -p ytd
kubectl --context=ytd get nodes
kubectl --context=ytd get storageclass standard
helm version
kubectl --context=ytd apply -f namespace.yaml
```

Нужна StorageClass `standard`, предоставляемая storage-provisioner minikube.
Если её нет, сначала разберись с addon; для другого имени поправь
`server.dataStorage.storageClass` в `vault/values.yaml`.
Minikube local storage не является отказоустойчивым: PVC может быть привязан
к одной ноде и не пережить её потерю. Не удаляй профиль или Docker volumes.

Зафиксированные версии: Vault Helm chart `0.34.1`, Vault `2.0.4`,
ESO Helm chart `2.12.0`. Values подготовлены под эти версии;
при обновлении повторно проверь API и значения chart.
[Vault chart release](https://github.com/hashicorp/vault-helm/releases/tag/v0.34.1),
[ESO chart](https://github.com/external-secrets/external-secrets/releases/tag/helm-chart-2.12.0).

## 2. Установка Vault

```sh
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update hashicorp
helm upgrade --install vault hashicorp/vault \
  --version 0.34.1 --kube-context ytd \
  --namespace vault --create-namespace \
  -f vault/values.yaml
kubectl --context=ytd -n vault get pods,pvc,svc
```

Здесь специально нет `--wait`: до init/unseal pod `vault-0` будет `Running`,
но не `Ready` (обычно `0/1`). Дождись `Running`; `Pending` требует проверки PVC
и событий, а не попытки unseal. [Vault Helm](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/helm).

В minikube StorageClass `standard` использует hostPath: каталог PVC может
создаваться как `root:root`, и одного `fsGroup` недостаточно для записи.
В values предусмотрен init-контейнер `data-permissions`: только он запускается
как root, меняет владельца PVC на `100:1000` и права его корневого каталога
на `0700`. Сам Vault остаётся non-root (`UID 100`, `GID 1000`).
Это локальное решение для лаборатории с hostPath, не повод запускать Vault
как root или ставить права `777`.
[Особенности hostPath](https://kubernetes.io/docs/concepts/storage/volumes/#hostpath).

### Если установка уже была выполнена без исправления прав

Ошибка `mkdir /vault/data/core: permission denied` означает, что процесс
Vault не может записать данные в PVC. После обновления `vault/values.yaml`
примени chart повторно и пересоздай **только pod**, сохранив PVC:

```sh
helm upgrade --install vault hashicorp/vault \
  --version 0.34.1 --kube-context ytd \
  --namespace vault --create-namespace \
  -f vault/values.yaml
kubectl --context=ytd -n vault delete pod vault-0
kubectl --context=ytd -n vault get pods -w
```

Chart использует `OnDelete`, поэтому одного Helm upgrade недостаточно:
старый pod не получит init-контейнер автоматически. Пересоздание временно
останавливает Vault; данные на PVC сохраняются, CLI token cache теряется.
Дождись нового pod `Running` и останови просмотр через Ctrl+C.
Не жди `Ready` до init/unseal.

```sh
kubectl --context=ytd -n vault logs vault-0 -c data-permissions
kubectl --context=ytd -n vault exec vault-0 -- sh -c 'id; ls -ldn /vault/data; test -w /vault/data && echo writable'
kubectl --context=ytd -n vault exec vault-0 -- vault status
```

Ожидается владелец `100:1000` и `writable`. Если `Initialized: false`,
перейди к init ниже. Если `Initialized: true`, повторный init не нужен:
используй сохранённый unseal key. Не удаляй PVC и не очищай `/vault/data`.
При `Init:Error` проверь лог init-контейнера и события pod; namespace
с enforced Restricted Pod Security не разрешит этот root init-контейнер.

## 3. Инициализация и unseal

Только один раз для нового хранилища выполни:

```sh
kubectl --context=ytd -n vault exec -it vault-0 -- \
  vault operator init -key-shares=1 -key-threshold=1
```

Команда намеренно показывает `Unseal Key 1` и `Initial Root Token`.
Сохрани их в менеджере паролей вне кластера, не в репозитории, ConfigMap
или Kubernetes Secret. Один ключ и порог один выбраны только для лаборатории.
Не отправляй вывод в чат или логи CI. Потеря unseal key может сделать данные
недоступными. Повторный init для существующего хранилища не нужен.
[operator init](https://developer.hashicorp.com/vault/docs/commands/operator/init).

Разблокируй Vault — команда спросит ключ скрыто:

```sh
kubectl --context=ytd -n vault exec -it vault-0 -- vault operator unseal
kubectl --context=ytd -n vault exec vault-0 -- vault status
kubectl --context=ytd -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s
```

Ожидается `Initialized: true`, `Sealed: false`, pod `Ready`.
У sealed Vault команда `vault status` возвращает код 2 — это не обязательно сбой.

## 4. Вход администратора и включение KV v2

Vault CLI уже находится в контейнере, устанавливать его на MacBook не нужно.
Введи initial root token в скрытом приглашении, не аргументом команды:

```sh
kubectl --context=ytd -n vault exec -it vault-0 -- vault login -no-print
kubectl --context=ytd -n vault exec vault-0 -- vault secrets enable -path=secret kv-v2
```

CLI временно сохраняет token в `$HOME/.vault-token` внутри pod.
Root нужен здесь для первоначальной настройки, но не используется оператором
и не передаётся приложению. В конце инструкции удалим token из CLI cache.
При повторном прохождении пропускай enable, если mount `secret/` уже существует.
[Vault login](https://developer.hashicorp.com/vault/docs/commands/login).

## 5. Запись нескольких ключей без файлов с паролями

Все креды приложения хранятся в одной записи `secret/shoplist`.
Используй реальные имена переменных, которые ожидает образ shoplist;
`POSTGRES_PASSWORD` ниже — пример. Не запускай скрытый ввод с `set -x`.

Для **первого ключа в новой записи** выполни в zsh:

```zsh
read -r 'secret_key?Первый ключ (например POSTGRES_PASSWORD): '
read -rs 'secret_value?Значение (скрытый ввод): '
printf '\n'
printf '%s' "$secret_value" |
  kubectl --context=ytd -n vault exec -i vault-0 -- \
    vault kv put -mount=secret shoplist "${secret_key}=-"
unset secret_key secret_value
```

`put` заменяет запись целиком. Не повторяй его для добавления второго или
третьего ключа и не используй, если запись уже существует.
[kv put](https://developer.hashicorp.com/vault/docs/commands/kv/put).

Для **каждого следующего ключа или изменения существующего**:

```zsh
read -r 'secret_key?Ключ (например POSTGRES_USER): '
read -rs 'secret_value?Значение (скрытый ввод): '
printf '\n'
printf '%s' "$secret_value" |
  kubectl --context=ytd -n vault exec -i vault-0 -- \
    vault kv patch -mount=secret shoplist "${secret_key}=-"
unset secret_key secret_value
```

`patch` сохраняет остальные ключи. Значение передаётся через stdin,
не сохраняется в файле и не становится аргументом процесса.
Команды выводят метаданные версии, не значения записи.
[kv patch](https://developer.hashicorp.com/vault/docs/commands/kv/patch).

Если переходишь с уже существующего `shoplist-credentials`, введи в Vault
весь нужный набор ключей до включения синхронизации. Их имена можно посмотреть
через `kubectl --context=ytd -n ytd describe secret shoplist-credentials`
без раскрытия значений. Не удаляй действующий Secret для миграции.

## 6. Policy и Kubernetes authentication

Policy `vault/shoplist-read.hcl` даёт только `read` на `secret/data/shoplist`.
`data` в пути policy — особенность API KV v2; в ExternalSecret будет просто
`shoplist`, без `secret/data/`.

```sh
kubectl --context=ytd -n vault exec -i vault-0 -- \
  vault policy write shoplist-read - < vault/shoplist-read.hcl
kubectl --context=ytd -n vault exec vault-0 -- vault auth enable kubernetes
kubectl --context=ytd -n vault exec vault-0 -- \
  vault write auth/kubernetes/config \
    kubernetes_host=https://kubernetes.default.svc:443
kubectl --context=ytd -n vault exec vault-0 -- \
  vault write auth/kubernetes/role/shoplist \
    bound_service_account_names=shoplist-vault \
    bound_service_account_namespaces=ytd \
    audience=vault \
    token_policies=shoplist-read \
    token_no_default_policy=true \
    token_ttl=15m \
    token_max_ttl=1h
```

Если auth mount `kubernetes/` уже включён, повторно enable не выполняй.
Vault работает в pod и использует локальный service account token и CA
для TokenReview; chart выдаёт **ServiceAccount Vault** роль
`system:auth-delegator`. Не нужно копировать JWT в YAML или выдавать эту роль
ServiceAccount приложения. `audience=vault` совпадает с `audiences` в SecretStore.
[Kubernetes auth](https://developer.hashicorp.com/vault/docs/auth/kubernetes).

## 7. Установка External Secrets Operator

```sh
helm repo add external-secrets https://charts.external-secrets.io
helm repo update external-secrets
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version 2.12.0 --kube-context ytd \
  --namespace external-secrets --create-namespace \
  -f vault/external-secrets/values.yaml \
  --wait --timeout 5m
kubectl --context=ytd -n external-secrets get pods
kubectl --context=ytd get crd secretstores.external-secrets.io externalsecrets.external-secrets.io
```

Helm устанавливает CRD. В этой лаборатории controller ограничен namespace
`ytd`; ClusterSecretStore и cluster controllers не используются.
Разрешение создавать токены произвольных ServiceAccount отключено.
Отдельный Role ниже разрешает TokenRequest только для `shoplist-vault`.
[Установка ESO](https://external-secrets.io/latest/introduction/getting-started/).

## 8. Подключение shoplist и проверка синхронизации

```sh
kubectl --context=ytd apply -k vault/external-secrets
kubectl --context=ytd -n ytd wait --for=condition=Ready secretstore/shoplist-vault --timeout=120s
kubectl --context=ytd -n ytd wait --for=condition=Ready externalsecret/shoplist-credentials --timeout=120s
kubectl --context=ytd -n ytd describe secret shoplist-credentials
kubectl --context=ytd apply -k .
kubectl --context=ytd -n ytd rollout restart deployment/shoplist
kubectl --context=ytd -n ytd rollout status deployment/shoplist --timeout=120s
```

Что создаётся отдельным Kustomization:

- `shoplist-vault` ServiceAccount и ограниченный Role/RoleBinding для ESO.
- Namespaced SecretStore `shoplist-vault`: адрес Vault, KV v2, auth role.
- ExternalSecret `shoplist-credentials`: перенос всех ключей записи `shoplist`
  в существующий или новый Kubernetes Secret с тем же именем каждую минуту.

Deployment уже использует `secretRef.name: shoplist-credentials`; менять его
ServiceAccount на `shoplist-vault` не нужно. Последний — identity для ESO,
а не для приложения.
[Vault provider](https://external-secrets.io/latest/provider/hashicorp-vault/).

Выбраны `creationPolicy: Orphan` и `deletionPolicy: Retain`: удаление
ExternalSecret не удалит целевой Secret, а потеря источника не должна стирать
последнюю синхронизированную копию. Это удобно для обучения и отката,
но оставляет старые значения, которые впоследствии нужно удалять осознанно.
До миграции заполни всю запись: ESO управляет содержимым целевого Secret,
а не просто добавляет один ключ к ручной конфигурации.
[ExternalSecret](https://external-secrets.io/latest/api/externalsecret/).

После перехода меняй значения **только в Vault**. Не используй ручной
`kubectl patch secret` или `secret.local.yaml` одновременно с ESO:
оператор перезапишет ручные изменения. ConfigMap остаётся для несекретных
настроек (`POSTGRES_HOST`, имя базы, порт и т. п.).

Удалить сохранённый CLI admin token после настройки:

```sh
kubectl --context=ytd -n vault exec vault-0 -- sh -c 'rm -f "$HOME/.vault-token"'
```

Это удаляет cache, но не отзывает root token. Для дальнейшего администрирования
лаборатории можно повторить скрытый login. Следующий учебный этап — отдельная
admin policy/auth и отзыв initial root token после проверки нового доступа.

## 9. Обновление ключа и применение в приложении

Повтори скрытый login из шага 4, затем блок `kv patch` из шага 5.
ESO обновляет Secret автоматически в пределах `refreshInterval: 1m`.
Можно запросить синхронизацию сразу:

```sh
kubectl --context=ytd -n ytd annotate externalsecret shoplist-credentials \
  force-sync="$(date +%s)" --overwrite
kubectl --context=ytd -n ytd get externalsecret shoplist-credentials \
  -o jsonpath='{.status.refreshTime}{"\n"}'
kubectl --context=ytd -n ytd describe externalsecret shoplist-credentials
```

Дождись нового `refreshTime` и успешного состояния (одно старое `Ready=True`
само по себе не доказывает, что последнее изменение уже синхронизировано).
Затем перезапусти Deployment:

```sh
kubectl --context=ytd -n ytd rollout restart deployment/shoplist
kubectl --context=ytd -n ytd rollout status deployment/shoplist --timeout=120s
kubectl --context=ytd -n vault exec vault-0 -- sh -c 'rm -f "$HOME/.vault-token"'
```

ESO не обновляет env работающего процесса. Изменение `POSTGRES_PASSWORD`
в Vault не меняет пароль PostgreSQL: смену в БД и у приложения согласовывай.
Это статические KV-креды, не Vault Database Secrets Engine.

## 10. Vault UI и перезапуск лаборатории

Для UI можно временно открыть localhost в отдельном терминале:

```sh
kubectl --context=ytd -n vault port-forward --address=127.0.0.1 pod/vault-0 8200:8200
```

Открой `http://127.0.0.1:8200`, вход через Token. Port-forward работает,
пока открыта команда; Ctrl+C его останавливает. Он нужен только для UI,
не для ESO или приложения. Не публикуй Vault UI в Интернет для этой лаборатории.

После остановки/запуска minikube или рестарта Vault pod:

```sh
minikube start -p ytd
minikube update-context -p ytd
kubectl --context=ytd -n vault get pods,pvc
kubectl --context=ytd -n vault exec -it vault-0 -- vault operator unseal
kubectl --context=ytd -n vault wait --for=condition=Ready pod/vault-0 --timeout=120s
```

Если Vault не sealed, unseal не требуется. При сохранном PVC init, запись
кредов и создание policy повторно не нужны. Пока Vault sealed, ESO не может
синхронизироваться, но последняя копия Kubernetes Secret остаётся.
PVC не заменяет резервную копию; перед удалением профиля нужна отдельная
проверенная копия хранилища. Для этого file backend не используй команды
`operator raft snapshot`: они относятся к Raft. Практику backup/restore
и TLS стоит проходить следующим этапом, прежде чем хранить важные креды.

## 11. Диагностика и возврат к ручным Secrets

```sh
kubectl --context=ytd -n vault describe pod vault-0
kubectl --context=ytd -n vault get pvc
kubectl --context=ytd -n vault logs vault-0 --tail=100
kubectl --context=ytd -n ytd describe secretstore shoplist-vault
kubectl --context=ytd -n ytd describe externalsecret shoplist-credentials
kubectl --context=ytd -n external-secrets logs deployment/external-secrets --tail=100
```

- Vault pod `Pending`: PVC, StorageClass, ресурсы и события scheduler.
- `mkdir /vault/data/core: permission denied`: раздел об исправлении прав
  после установки; init-контейнер должен завершиться успешно.
- Vault sealed / HTTP 503: выполнить unseal, не новый init.
- Login 403: namespace, имя ServiceAccount, audience и Vault role.
- TokenReview запрещён: проверить binding `vault-server-binding` и SA Vault.
- ESO не может создать JWT: проверить RoleBinding `shoplist-vault-token`;
  subject должен быть `external-secrets` в namespace `external-secrets`.
- Чтение 403: policy должна разрешать `secret/data/shoplist`.
- SecretSyncError / запись не найдена: KV mount `secret`, версия v2,
  путь `shoplist`, наличие записи и состояние Vault.
- Приложение использует старое значение: дождаться sync и выполнить rollout restart.

Не публикуй диагностический вывод, содержащий токены или значения Secrets.
Не используй `get secret -o yaml` или `vault kv get` для проверки наличия ключей,
если значения не нужно раскрывать.

Для возврата к ручному способу сначала останови синхронизацию:

```sh
kubectl --context=ytd -n ytd delete externalsecret shoplist-credentials
```

Из-за `Orphan` целевой Secret сохранится. Теперь можно использовать ручной
`patch` из README и перезапуск Deployment. Не удаляй namespace `vault`, PVC
или minikube профиль только ради отключения ESO.
