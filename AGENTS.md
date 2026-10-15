# Контекст проекта

Это инфраструктурный проект для запуска приложений в трёхнодовом minikube
на MacBook с Docker Desktop. Исходного кода приложений здесь нет: Deployment
используют готовые контейнерные образы. Общайся с пользователем на русском.
Подробная инструкция по развёртыванию и диагностике находится в `README.md`.

## Архитектура

- Профиль и kubectl context: `ytd`. Namespace приложений: `ytd`.
- Docker-сеть: `ytd-network`, подсеть `192.168.58.0/24`.
- Внешний трафик: Интернет → MikroTik (dst-nat 80/443) → домашний nginx
  reverse proxy → MacBook `192.168.30.37:8080` → Docker-прокси
  → NodePort `30080` → NGINX Gateway Fabric → Service → Pod.
- Compose-прокси имеет адрес `192.168.58.250`, чтобы не занимать адреса нод.
  Backend по умолчанию — контейнер ноды `ytd`, адрес разрешается через Docker DNS.
- GatewayClass: `nginx`; Gateway: `ytd-gateway`; NginxProxy: `ytd-proxy`.
- Текущие манифесты содержат только HTTP listener `http` на порту `8080`.
  Service приложений слушают порт `80`; контейнеры youtubedl и shoplist — `8000`,
  receipt — nginx на `80` с внутренним Uvicorn на `127.0.0.1:8000`.
- Приложения: `youtubedl` на `ytd.bakabuka.com` и `shoplist`
  на `shoplist.bakabuka.com`.
- Приложение receipt доступно на `receipt.bakabuka.com`; URL зависимости
  myexpenses задаётся в его ConfigMap и требует отдельной настройки сервиса/DNS.
- `externalTrafficPolicy: Cluster` нужен для доступа через выбранную ноду,
  даже если pod Gateway находится на другой ноде.

## Файлы

- `namespace.yaml` — namespace приложений.
- `gateway.yaml`, `nginx_proxy.yaml` — общий вход и NodePort Gateway.
- `ytd/` — Deployment, Service и HTTPRoute приложения youtubedl.
- `shoplist/` — Deployment, Service, HTTPRoute, ConfigMap и шаблон Secret.
- `receipt/` — Deployment, Service, HTTPRoute и ConfigMap приложения receipt.
- `kustomization.yaml` — явный список Kubernetes-ресурсов для `kubectl apply -k .`.
- `compose.yaml` — внешний Docker-прокси; это не Kubernetes-манифест.
- `docker-proxy.conf.template` — HTTP-прокси nginx с сохранением Host и WebSocket.
- `README.md` — создание кластера, установка контроллера, домены, TLS,
  секреты и диагностика. Примеры TLS не включены в текущий Kustomization.
- `VAULT.md`, `vault/` — необязательная домашняя лаборатория Vault + ESO:
  Helm values, Vault policy и отдельный Kustomization для синхронизации shoplist.
  Не включены в корневой Kustomization и не считаются развёрнутыми.

## Правила изменений

- Сохраняй разделение приложений по папкам и общий Gateway.
  Для нового приложения добавляй Deployment, Service, HTTPRoute и записи
  в `kustomization.yaml`. Согласовывай labels, selectors, порты и backendRefs.
- Не применяй `kubectl apply -f .`: в корне есть Compose и Kustomization.
- Gateway API CRD и NGINX Gateway Fabric устанавливаются отдельно до
  применения ресурсов проекта. Команды и версии зафиксированы в README;
  при обновлении проверяй совместимость, а не подставляй latest автоматически.
- Не добавляй одинаковые `--ports` при создании трёх нод: это приводит
  к конфликту портов Docker. Порт хоста публикуется через Compose-прокси.
- Не меняй основную конфигурацию домашнего nginx для остальных сайтов.
  Пользователь хочет отдельный virtual host только для `bakabuka.com`
  и `*.bakabuka.com`.
- TLS в README описан как два соединения: клиент → домашний nginx
  и домашний nginx → Gateway. Это не сквозной TLS passthrough.
  Сертификаты Let's Encrypt на этих участках управляются отдельно.
  Wildcard требует DNS-01; HTTP-01 применяется к отдельным именам.
- Не считай примеры из README уже развёрнутыми ресурсами.
  Проверяй текущие файлы и, при необходимости, состояние выбранного context.
- Изменения процесса развёртывания сопровождай обновлением README.
  Не исправляй несвязанные проблемы и не меняй версии образов без необходимости.

## Секреты и конфигурация

- `shoplist-config` содержит только несекретные настройки.
- Deployment shoplist подключает `shoplist-config` и `shoplist-credentials`
  через `envFrom`; ключи становятся переменными окружения приложения.
  Оба ресурса должны находиться в namespace `ytd`.
- Secret создаётся отдельно, например через скрытый ввод и stdin по README.
  Он намеренно не включён в `kustomization.yaml`, чтобы шаблон не перезаписывал
  реальные креды. `shoplist/secret.example.yaml` содержит только заглушки.
- Никогда не записывай реальные пароли, токены или приватные ключи в шаблоны,
  README, вывод инструментов или историю команд. Не читай значения действующих
  Secrets без явной необходимости и не показывай их пользователю.
- `shoplist/secret.local.yaml` исключён через `.gitignore`, но это не шифрование.
  `stringData` — открытый текст, `data` — base64, а не защита секрета.
- Не угадывай имена переменных приложения. Обновление `POSTGRES_PASSWORD`
  в Kubernetes не меняет пароль самой базы данных.
- После обновления ConfigMap/Secret с `envFrom` нужен rollout restart,
  чтобы работающие контейнеры получили новые значения.
- При переходе на ESO источником значений становится Vault; ручные изменения
  целевого Secret не совмещай с синхронизацией. Лаборатория использует один
  persistent Vault с ручным unseal и HTTP внутри кластера, не production setup.

## Проверка и безопасность операций

- Для локальной проверки без изменения кластера используй
  `kubectl kustomize .` и `docker compose config --quiet`.
- При доступном кластере и установленных CRD можно проверить ресурсы командой
  `kubectl --context=ytd apply --dry-run=server -k .`.
- Для диагностики используй явные `--context=ytd` и `-n ytd`:
  `get pods`, `describe`, `logs deployment/shoplist --tail=100`,
  `logs deployment/youtubedl --tail=100` и статусы Gateway/HTTPRoute.
- Не удаляй кластер, профили, Docker-сети, volumes или данные PostgreSQL
  без явного согласования. Изменение файлов не означает разрешение на apply,
  rollout restart, установку контроллеров или выпуск реальных сертификатов.
- В проекте нет тестов приложения; проверяй согласованность манифестов
  и команды документации, не добавляя несвязанные тестовые инструменты.
