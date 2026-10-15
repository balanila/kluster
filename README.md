# ytd.bakabuka.com в minikube

Манифесты требуют GatewayClass `nginx` и NGINX Gateway Fabric.
В новом кластере сначала установи Gateway API CRD и контроллер.
Создаётся отдельный namespace `ytd`, Gateway с HTTP listener на порту 8080,
HTTPRoute, Service и Deployment с одной репликой и одним контейнером
`balanial/youtubedl:1.1.1`. Порт приложения 8000 проверен по метаданным образа.
Сначала инструкция запускает текущую HTTP-конфигурацию. Раздел «TLS внутри
кластера» описывает переход на HTTPS: сертификат хранится в Kubernetes,
а домашний nginx использует HTTPS upstream к Gateway. Клиентский TLS
завершается на домашнем nginx, второе TLS-соединение — внутри кластера.
Так меняется только virtual host этих доменов на основном сервере.
Примеры TLS ниже нужно создать и применить отдельно; текущие файлы проекта
пока содержат только HTTP listener.

## Кластер на MacBook

Схема доступа:

```text
Интернет → MikroTik (dst-nat 80/443) → домашний nginx (TLS)
  → MacBook:8080 → Docker-прокси → ytd:30080 (NodePort)
  → Gateway:8080 → Service youtubedl:80 → Pod:8000
```

Запусти Docker Desktop. Для трёх нод создай отдельный профиль и явную сеть:

```sh
minikube start -p ytd --driver=docker --container-runtime=containerd --kubernetes-version=v1.37.1 --nodes=3 --network=ytd-network --subnet=192.168.58.0/24
kubectl --context=ytd get nodes
minikube profile ytd
minikube update-context
kubectl config use-context ytd
```

Не добавляй `--ports`: в показанном запуске minikube одинаковые пробросы
применяются к каждой ноде и конфликтуют. Порт MacBook публикует Docker-прокси.
Для Kubernetes 1.37.1 требуется minikube с поддержкой этой версии; здесь
используется minikube 1.39.0. Runtime внутри нод — containerd; сами ноды
и внешний прокси по-прежнему работают через Docker Desktop.
`--listen-address` для minikube здесь не нужен. Старый профиль не удаляется.
Если его контейнер занимает порт 8080, останови старый кластер:

```sh
minikube stop -p minikube
```

Это остановит приложения старого кластера, сохранив профиль и данные.
Если три ноды уже созданы без пробросов, используй их context вместо `ytd`
и укажи их Docker-сеть и контейнер ноды в настройках Compose ниже.

## Установка Gateway Fabric

Требуется Helm 3 или новее. Для нового профиля `ytd`:

```sh
kubectl --context=ytd kustomize 'https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.7.2' | kubectl --context=ytd apply -f -
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric --version 2.7.2 --kube-context ytd --namespace nginx-gateway --create-namespace --wait
kubectl --context=ytd get gatewayclass nginx
```

GatewayClass должен иметь `Accepted=True`. Chart также устанавливает CRD
`NginxProxy`. Если контроллер уже установлен, проверь поддержку
`gateway.nginx.org/v1alpha2` и наличие GatewayClass `nginx`.

## Применение

Из текущей папки:

```sh
kubectl --context=ytd apply -k .
kubectl --context=ytd -n ytd rollout status deployment/youtubedl
kubectl --context=ytd -n ytd get gateway,httproute,svc,pods
```

`kustomization.yaml` перечисляет только Kubernetes-ресурсы. Используй `-k .`,
а не `-f .`: во втором случае kubectl также читает Docker Compose и файл
Kustomization как обычные Kubernetes-манифесты. Kustomize помещает Namespace
перед ресурсами приложения. CRD и Gateway Fabric должны быть установлены
отдельно до применения этой конфигурации.

Для Gateway ожидается `Programmed=True`, для HTTPRoute — `Accepted=True`
и `ResolvedRefs=True` в статусе:

```sh
kubectl --context=ytd -n ytd describe gateway ytd-gateway
kubectl --context=ytd -n ytd describe httproute youtubedl
```

## Доступ с reverse proxy на порт 8080 локальной машины

`nginx_proxy.yaml` задаёт NodePort 30080 для listener 8080.
Gateway Fabric автоматически создаёт Service `ytd-gateway-nginx`;
у него ожидается `8080:30080/TCP`. В NginxProxy явно задано
`externalTrafficPolicy: Cluster`: NodePort выбранной ноды направляет запросы
к pod Gateway, даже если он работает на другой ноде.
Это переопределяет настройку `Local` в chart Gateway Fabric, при которой
нода без локального pod Gateway не принимает внешний трафик.

`compose.yaml` запускает nginx в сети `ytd-network` и публикует
`0.0.0.0:8080` на MacBook. Из текущей папки:

```sh
docker compose config --quiet
docker compose up -d
docker compose ps
```

Терминал и `kubectl port-forward` не нужны. Прокси работает в фоне с политикой
`restart: unless-stopped`. Он сохраняет `Host` и переданные домашним nginx
заголовки `X-Forwarded-*`, а адрес ноды обновляет через DNS Docker.
Если используешь другой профиль, создай в этой папке `.env`, например:

```dotenv
MINIKUBE_NETWORK=minikube
MINIKUBE_NODE=minikube
MINIKUBE_PROXY_IP=192.168.49.250
```

Имена сети и контейнера ноды проверь через `docker network ls` и `docker ps`.
Подсеть проверь через `docker network inspect ИМЯ_СЕТИ`. Прокси получает
статический адрес `192.168.58.250` по умолчанию. Для другой подсети укажи
свободный адрес в `MINIKUBE_PROXY_IP`. Не используй адреса нод: в этой
схеме три ноды занимают `.2`, `.3` и `.4`. Динамический адрес прокси может
занять адрес ещё не запущенной ноды и помешать старту кластера.
После изменения `.env` снова выполни `docker compose up -d`.

В настройках Docker Desktop можно включить запуск при входе в систему.
Один раз выбери активный профиль и контекст kubectl:

```sh
minikube profile ytd
minikube update-context
kubectl config use-context ytd
```

После этого для запуска существующего кластера достаточно:

```sh
minikube start
docker compose up -d
kubectl get nodes
```

Параметры драйвера, сети и нод сохраняются в профиле. Если kubectl не может
подключиться после перезапуска, при запущенном Docker Desktop выполни
`minikube start`, затем `minikube update-context` и
`kubectl config use-context ytd`. В отдельной IDE или терминале проверь,
что переменная `KUBECONFIG` не указывает на другой файл конфигурации.

Политика рестарта прокси не запускает minikube самостоятельно. MacBook должен
оставаться включённым и не переходить в сон для доступности приложения.
Если кластер недоступен, прокси возвращает ошибку upstream; после восстановления
ноды и NodePort запросы возобновляются.

Порт Mac 8080 должен быть свободен. Разреши входящие подключения к Docker-прокси
в firewall macOS. Для диагностики и остановки:

```sh
docker compose logs --tail=100 proxy
docker compose exec proxy nginx -t
docker compose down
```

На внешнем nginx сохрани исходный заголовок `Host`. Пример HTTP-конфигурации;
замени `MAC_IP` на доступный с сервера IP локальной машины:

```nginx
server {
    listen 80;
    server_name ytd.bakabuka.com;

    location / {
        proxy_pass http://MAC_IP:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 600s;
    }
}
```

Закрепи IP MacBook через DHCP lease на MikroTik. DNS-запись домена должна
указывать на внешний адрес MikroTik. TLS завершается на домашнем nginx;
проброс 8443 на MacBook не требуется. Проверка на Mac:

```sh
curl -v -H 'Host: ytd.bakabuka.com' http://127.0.0.1:8080/
```

С домашнего сервера проверь тот же URL, заменив `127.0.0.1` на IP MacBook.
HTTPRoute обслуживает только `ytd.bakabuka.com`. Для других поддоменов нужны
отдельные HTTPRoute и сервисы.

Описание маршрутизации Gateway → HTTPRoute → Service:
[документация NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/traffic-management/basic-routing/).

- [Установка Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/get-started/)
- [Внешние сети Docker Compose](https://docs.docker.com/compose/how-tos/networking/)
- [Конфликт --ports при добавлении нод](https://github.com/kubernetes/minikube/issues/16766)

## Добавление других доменов

Для `app.bakabuka.com` создай DNS-запись, указывающую на внешний IP MikroTik.
Если DNS wildcard `*.bakabuka.com` уже существует, отдельная запись обычно
не нужна. Домашний nginx должен принимать этот домен через
`server_name *.bakabuka.com` и передавать исходный `Host` на MacBook.
DNS wildcard не создаёт маршруты в Kubernetes: каждый backend настраивается
через HTTPRoute.

### Другой домен для существующего приложения

Добавь домен в `ytd/httproute.yaml`:

```yaml
  hostnames:
    - ytd.bakabuka.com
    - app.bakabuka.com
```

Оба домена будут вести в Service `youtubedl`. Примени и проверь:

```sh
kubectl apply -k .
curl --max-time 15 -H 'Host: app.bakabuka.com' http://127.0.0.1:8080/
```

### Новый домен для отдельного приложения

Создай Deployment и Service приложения в namespace `ytd`. Можно взять
`ytd/deployment.yaml` и `ytd/service.yaml` за образец, но заменить имена ресурсов,
`app` в selector и labels, образ и порт контейнера. У Service `targetPort`
должен совпадать с портом приложения или именем его containerPort.
У каждого приложения должны быть собственные labels, чтобы Service
не выбирал pod другого приложения.

После создания Service `app` с портом 80 создай `app-route.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: app
  namespace: ytd
spec:
  parentRefs:
    - name: ytd-gateway
      sectionName: http
  hostnames:
    - app.bakabuka.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: app
          port: 80
```

Добавь пути новых Deployment, Service и HTTPRoute в `resources` файла
`kustomization.yaml`, затем выполни `kubectl apply -k .`. Без добавления
в `resources` новые файлы не применяются. Один Gateway обслуживает несколько
доменов; новый NodePort и Docker-прокси для каждого домена не нужны.

Проверь `Accepted=True` и `ResolvedRefs=True`:

```sh
kubectl -n ytd describe httproute app
curl --max-time 15 -H 'Host: app.bakabuka.com' http://127.0.0.1:8080/
```

В текущем Gateway `allowedRoutes.namespaces.from: Same`, поэтому маршруты
должны находиться в namespace `ytd`. Для приложения в другом namespace
нужно разрешить подключение маршрутов из этого namespace в listener
Gateway, а в HTTPRoute указать `parentRefs.namespace: ytd`. Размещай маршрут
и его Service в одном namespace; ссылка на Service в другом namespace
дополнительно требует ReferenceGrant.

## Let's Encrypt: пример для ytd.bakabuka.com

Этот сценарий получает и автоматически продлевает сертификат внутри кластера
через cert-manager. Используется HTTP-01 для конкретного домена
`ytd.bakabuka.com`; учётные данные DNS-провайдера не нужны. Сертификат
`*.bakabuka.com` этим методом получить нельзя: wildcard требует DNS-01.
Сначала получи сертификат по этому разделу, затем выполни шаги 2–8 раздела
«TLS внутри кластера». Ручной импорт Secret из шага 1 в этом случае пропусти.

### 1. Как проходит проверка домена

```text
Certificate ytd-tls → cert-manager → заказ сертификата у Let's Encrypt
  → временные HTTPRoute, Service и pod cm-acme-http-solver-...

Let's Encrypt GET http://ytd.bakabuka.com/.well-known/acme-challenge/TOKEN
  → публичный порт 80 MikroTik → домашний nginx:80
  → 192.168.30.37:8080 → Docker HTTP-прокси
  → NodePort 30080 → Gateway HTTP:80
  → временный HTTPRoute → solver pod с ответом для TOKEN

Успешная проверка → сертификат и ключ в Secret ytd-tls
  → Gateway читает Secret и завершает HTTPS на listener 8443
```

Маршрут проверки с точным путём имеет приоритет перед маршрутом приложения
с PathPrefix `/`. Временные ресурсы удаляются после проверки. HTTP-01
выполняется снаружи на стандартном порту 80; внутренние пробросы портов
допустимы. Отдельно solver cert-manager для Gateway API требует HTTP listener
с портом 80 в самом Gateway. [Документация solver](https://cert-manager.io/docs/configuration/acme/http01/),
[проверки Let's Encrypt](https://letsencrypt.org/docs/challenge-types/).

### 2. DNS, MikroTik и твой домашний nginx

Проверь, что A-запись `ytd.bakabuka.com` указывает на публичный IPv4 MikroTik,
а dst-nat внешнего TCP:80 направляет запросы на домашний nginx:80.
Если есть AAAA-запись, IPv6-путь до сервиса также должен работать;
убери неработающую AAAA-запись. MacBook должен иметь адрес 192.168.30.37,
Docker Desktop и minikube должны работать во время выдачи и продления.

Твоя HTTP-конфигурация уже передаёт нужные Host и URI. Для неё достаточно
следующего блока. `map` размести внутри `http`, вне `server`, если он ещё
не определён в другом месте:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    server_name bakabuka.com *.bakabuka.com;

    location / {
        proxy_pass http://192.168.30.37:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 600s;
    }
}
```

Изменён `X-Forwarded-For`: теперь он дополняет цепочку адресов.
Отдельный location для ACME не требуется. Не блокируй
`/.well-known/acme-challenge/` правилами для скрытых файлов, авторизацией
или отдельным upstream. На этапе выдачи оставь проксирование HTTP без
принудительного redirect на домашнем nginx. После включения HTTPS redirect
настраивается в Gateway, как описано ниже.

С внешней сети сначала проверь `http://ytd.bakabuka.com/`. Ответ приложения
подтверждает основной HTTP-путь. Для URL с произвольным ACME TOKEN до запуска
проверки нет ожидаемого solver-ответа: тестировать нужно реальный TOKEN
из созданного cert-manager Challenge.

### 3. HTTP listener Gateway для ACME

До создания Certificate измени `port` существующего listener `http`
в `gateway.yaml` с 8080 на 80. Остальные поля Gateway сохрани.
В `nginx_proxy.yaml` измени только соответствующий `listenerPort`:

```yaml
      nodePorts:
        - port: 30080
          listenerPort: 80
```

Примени и проверь:

```sh
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n ytd get svc ytd-gateway-nginx
curl --max-time 15 -H 'Host: ytd.bakabuka.com' http://127.0.0.1:8080/
```

Service Gateway теперь показывает `80:30080/TCP`. Порт MacBook остаётся
8080, Docker-прокси по-прежнему обращается к NodePort 30080, поэтому
`compose.yaml`, `docker-proxy.conf.template` и домашний HTTP nginx
из-за этого изменения править не нужно. Listener сохраняет имя `http`
и разрешение маршрутов из namespace `ytd`.

### 4. Установка cert-manager

Gateway API и Gateway Fabric должны быть установлены ранее. Команда
устанавливает cert-manager 1.21.2 с поддержкой Gateway API:

```sh
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.2 --kube-context ytd \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set config.gatewayAPI.enabled=true \
  --wait --timeout 5m
kubectl -n cert-manager get pods
```

Эта настройка соответствует актуальной схеме cert-manager 1.21;
параметры конфигурации старых версий могут отличаться.
[Установка Helm chart](https://cert-manager.io/docs/installation/helm/).

### 5. Пробная выдача через staging

Сначала проверь сеть через staging Let’s Encrypt. Этот сертификат
не доверен браузерами. Создай `letsencrypt-staging.yaml`, заменив
`admin@bakabuka.com` на свой действующий email:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: ytd
spec:
  acme:
    email: admin@bakabuka.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging-account
    solvers:
      - http01:
          gatewayHTTPRoute:
            serviceType: ClusterIP
            parentRefs:
              - group: gateway.networking.k8s.io
                kind: Gateway
                name: ytd-gateway
                namespace: ytd
                sectionName: http
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ytd-tls-staging
  namespace: ytd
spec:
  secretName: ytd-tls-staging
  dnsNames:
    - ytd.bakabuka.com
  issuerRef:
    name: letsencrypt-staging
    kind: Issuer
    group: cert-manager.io
```

```sh
kubectl apply -f letsencrypt-staging.yaml
kubectl -n ytd get certificate,certificaterequest,orders,challenges
kubectl -n ytd wait --for=condition=Ready certificate/ytd-tls-staging --timeout=5m
```

Если ожидание закончилось таймаутом, сначала исправь причину через диагностику
ниже. Не переходи к production при неработающем staging.
Secret `letsencrypt-staging-account` хранит ключ ACME-аккаунта Issuer;
`ytd-tls-staging` — сертификат и ключ сайта. Оба создаёт cert-manager.

### 6. Доверенный сертификат production

После успешной staging-проверки создай `letsencrypt-prod.yaml` с тем же
реальным email:

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-prod
  namespace: ytd
spec:
  acme:
    email: admin@bakabuka.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - http01:
          gatewayHTTPRoute:
            serviceType: ClusterIP
            parentRefs:
              - group: gateway.networking.k8s.io
                kind: Gateway
                name: ytd-gateway
                namespace: ytd
                sectionName: http
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ytd-tls
  namespace: ytd
spec:
  secretName: ytd-tls
  dnsNames:
    - ytd.bakabuka.com
  issuerRef:
    name: letsencrypt-prod
    kind: Issuer
    group: cert-manager.io
```

Добавь `letsencrypt-prod.yaml` в `resources` файла `kustomization.yaml`.
Staging-файл оставь отдельным тестом, вне основной конфигурации.

```sh
kubectl apply -k .
kubectl -n ytd wait --for=condition=Ready certificate/ytd-tls --timeout=5m
kubectl -n ytd get certificate ytd-tls
kubectl -n ytd get secret ytd-tls
```

Ожидаемое состояние после успешной выдачи, а не результат проверки
из этой инструкции:

```text
NAME      READY   SECRET
ytd-tls   True    ytd-tls
```

Не создавай Secret `ytd-tls` вручную: его поддерживает cert-manager.
При добавлении `app.bakabuka.com` в тот же сертификат добавь домен
в `Certificate.spec.dnsNames`. Для нового приложения нужны также
HTTPRoute, подходящий HTTPS listener и работающий DNS/HTTP-путь проверки.
Наличие `server_name *.bakabuka.com` само по себе не выдаёт wildcard-сертификат.

### 7. Включение HTTPS с завершением TLS в кластере

Когда production Certificate стал `Ready=True`, выполни шаги 2–5
следующего раздела: добавь HTTPS listener с `certificateRefs.name: ytd-tls`,
NodePort 30443, HTTPS parentRef и Docker TCP-прокси на 8443.
В примере NginxProxy ниже для HTTP уже используется `listenerPort: 80`.

На домашнем сервере добавь HTTPS server в virtual host `bakabuka.conf`
по полному примеру следующего раздела. Он принимает клиентский TLS
и открывает новое HTTPS-соединение к 192.168.30.37:8443.
Для этого домашнему nginx нужен собственный сертификат для этих доменов;
cert-manager в Kubernetes управляет отдельным сертификатом Gateway.
Используй существующий ACME-механизм домашнего сервера для его сертификата.
Общий `stream` на основном сервере и перенос портов других сайтов не нужны.
HTTP server на 80 продолжает передавать проверки ACME в кластер.

Проверка на MacBook:

```sh
curl --max-time 15 --resolve ytd.bakabuka.com:8443:127.0.0.1 \
  https://ytd.bakabuka.com:8443/
```

После успешной проверки включи redirect в Gateway по шагу 8 ниже.
Временный ACME HTTPRoute с точным challenge-путём остаётся приоритетнее
redirect с PathPrefix `/`, что позволяет продлевать сертификат через HTTP.

### 8. Продление и диагностика Let's Encrypt

cert-manager автоматически планирует продление и обновляет Secret,
а Gateway Fabric подхватывает сертификат. Состояние и даты:

```sh
kubectl -n ytd describe certificate ytd-tls
kubectl -n ytd get certificate ytd-tls \
  -o jsonpath='{.status.notAfter}{"\n"}{.status.renewalTime}{"\n"}'
```

Для HTTP-01 внешний порт 80 и вся цепочка до solver должны оставаться
доступными и при продлении. Если MacBook был выключен или кластер удалён,
автоматическое продление в нём работать не может.

При ошибке выдачи:

```sh
kubectl -n ytd describe issuer letsencrypt-staging
kubectl -n ytd describe certificate ytd-tls-staging
kubectl -n ytd get orders,challenges
kubectl -n ytd describe challenges
kubectl -n ytd get httproute,svc,pods
kubectl -n cert-manager logs deployment/cert-manager --tail=100
```

Для production подставь соответствующие имена Issuer и Certificate.
В Challenge видны домен и token. Пока challenge активен, запрос
`http://ytd.bakabuka.com/.well-known/acme-challenge/РЕАЛЬНЫЙ_TOKEN`
из внешней сети должен вернуть ответ solver, а не HTML приложения или 404.
Проверь условия Accepted/ResolvedRefs временного HTTPRoute.

cert-manager также выполняет self-check изнутри кластера. Если внешний
запрос успешен, а self-check зависает, проверь DNS и доступ из домашней
сети к публичному адресу MikroTik: может потребоваться hairpin NAT.
Альтернатива — split DNS, направляющий домен внутри сети на домашний
nginx:80, при сохранении публичной DNS-записи для Let's Encrypt.

## Откуда берутся сертификаты Let's Encrypt

В выбранной схеме два HTTPS-соединения и две точки установки сертификатов:

| Соединение | Кто получает сертификат Let's Encrypt | Где хранится |
| --- | --- | --- |
| Браузер → основной nginx | ACME-клиент основного сервера, например Certbot | Файлы fullchain.pem и privkey.pem основного сервера |
| Основной nginx → Gateway | cert-manager в Kubernetes | Secret ytd-tls в namespace ytd |

Пути в конфиге nginx — результат выдачи, а не уже существующие файлы.
Эта инструкция сама не запрашивает сертификаты. cert-manager не переносит
созданный им Secret на основной сервер. Сертификаты в обеих точках могут
быть выданы Let's Encrypt независимо; приватные ключи копировать между
серверами не требуется.

### Основной nginx: выдача для bakabuka.com и *.bakabuka.com

Для wildcard нужен DNS-01. Ниже пример выдачи с ручной DNS-проверкой,
который подходит независимо от DNS-провайдера. Выполняй на основном сервере,
где установлен Certbot, до включения HTTPS server-блока с путями сертификата.
Замени email на свой:

```sh
sudo certbot certonly \
  --manual --preferred-challenges dns \
  --server https://acme-v02.api.letsencrypt.org/directory \
  --cert-name bakabuka.com \
  --email admin@bakabuka.com --agree-tos \
  -d bakabuka.com -d '*.bakabuka.com'
```

Certbot попросит добавить TXT-записи `_acme-challenge.bakabuka.com`
в панели авторитетного DNS-провайдера. Используй значения из его вывода.
Для корневого домена и wildcard могут понадобиться разные TXT-значения
под одним именем: добавляй запрошенные значения, сохраняя ещё необходимые
для текущей проверки. Дождись появления записей в DNS, затем продолжи
в терминале Certbot:

```sh
dig +short TXT _acme-challenge.bakabuka.com
```

После успешной выдачи Certbot создаст:

```text
/etc/letsencrypt/live/bakabuka.com/fullchain.pem
/etc/letsencrypt/live/bakabuka.com/privkey.pem
```

Это именно файлы для `ssl_certificate` и `ssl_certificate_key` следующего
virtual host. Проверь пути через `sudo certbot certificates`, затем
проверь nginx и выполни reload. Если nginx в Docker, каталог
`/etc/letsencrypt` должен быть доступен внутри контейнера; монтируй весь
каталог, чтобы ссылки `live` на файлы `archive` разрешались корректно.

Ручной DNS-01 без hooks не обеспечивает автопродление. Для постоянной
работы используй Certbot DNS-plugin своего провайдера либо ACME-клиент,
уже обслуживающий сертификаты на основном сервере. После продления нужно
выполнить reload nginx. Точная автоматизация зависит от DNS-провайдера.
[Документация Certbot](https://eff-certbot.readthedocs.io/en/stable/using.html),
[DNS-01 Let's Encrypt](https://letsencrypt.org/docs/challenge-types/).

### Gateway: отдельная выдача внутри Kubernetes

Раздел «Let's Encrypt: пример для ytd.bakabuka.com» выше описывает автоматическую
выдачу cert-manager через HTTP-01, сначала staging, затем production.
Итог — Secret `ytd-tls`; файлы основного nginx для этой выдачи не используются.
Для wildcard в Gateway также потребуется DNS-01 solver своего провайдера.
Сертификат основного nginx на `*.bakabuka.com` не заменяет сертификат
Gateway: каждый HTTPS listener в кластере должен иметь Secret с сертификатом,
покрывающим его hostname.

## Один virtual host bakabuka.conf для HTTP и HTTPS

На основном сервере nginx уже принимает 80/443 и обслуживает другие сайты.
Чтобы менять только домены `bakabuka.com` и `*.bakabuka.com`, используй
обычный HTTP virtual host с двумя server-блоками, подключаемый внутри
существующего `http`. Остальные virtual hosts и их порты остаются прежними.

```text
HTTP: клиент → домашний nginx:80 → MacBook:8080 → Gateway HTTP
HTTPS: клиент → домашний nginx:443 (клиентский TLS)
  → новое HTTPS-соединение к MacBook:8443
  → Docker TCP-прокси → Gateway HTTPS (TLS upstream) → приложение HTTP
```

В этой схеме TLS завершается в двух местах: клиентское соединение на
основном nginx, соединение nginx с кластером — на Gateway. Передать исходный
клиентский TLS напрямую в Gateway через один обычный HTTP virtual host
невозможно: для этого понадобились бы изменения общего listener через
stream. Здесь используется HTTPS upstream, чтобы сохранить текущую
архитектуру основного сервера.

Полное содержимое отдельного файла `bakabuka.conf`:

```nginx
server {
    listen 80;
    server_name bakabuka.com *.bakabuka.com;

    location / {
        proxy_pass http://192.168.30.37:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_connect_timeout 5s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}

server {
    listen 443 ssl;
    server_name bakabuka.com *.bakabuka.com;

    ssl_certificate /etc/letsencrypt/live/bakabuka.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bakabuka.com/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass https://192.168.30.37:8443;
        proxy_http_version 1.1;
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify on;
        proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
        proxy_ssl_verify_depth 3;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_connect_timeout 5s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
```

Сначала выпусти сертификат основного сервера по разделу выше; без его файлов
этот HTTPS server-блок не пройдёт `nginx -t`. Подставь пути из вывода Certbot.
Для всего набора имён нужен сертификат с SAN `bakabuka.com` и
`*.bakabuka.com`; wildcard Let's Encrypt выдаётся через DNS-01.
Если обслуживается только `ytd.bakabuka.com`, допустим отдельный сертификат
на это имя и соответствующий `server_name` на этапе настройки.
Сертификат на основном nginx и сертификат Gateway могут быть разными.
Основной сертификат продлевает ACME-клиент этого сервера, сертификат
Gateway — cert-manager. Выпуск cert-manager не устанавливает сертификат
автоматически на основной сервер.

`proxy_ssl_name $host` передаёт домен в SNI и проверяет сертификат upstream
по этому домену вместо IP 192.168.30.37. Gateway должен иметь соответствующие
HTTPS listeners и сертификаты для каждого проксируемого домена.
Путь `/etc/ssl/certs/ca-certificates.crt` — системный CA bundle для типичных
Linux-установок; если он другой, подставь свой путь. Используй production
Let’s Encrypt сертификат Gateway: staging не доверен системными CA.
Описание директив: [nginx HTTPS upstream](https://nginx.org/en/docs/http/ngx_http_proxy_module.html).

Существующий `map $http_upgrade $connection_upgrade` должен оставаться
внутри `http`, вне `server`. Если он ещё не определён, добавь его один раз:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
```

Для этой схемы stream требуется только у Docker TCP-прокси на MacBook,
как описано ниже. Основной сервер продолжает использовать свои опубликованные
80/443 и существующее подключение HTTP virtual hosts. У доменов нужны
HTTPRoute в кластере: `server_name` сам по себе их не создаёт.
На домашнем сервере проверь конфигурацию и выполни reload:

```sh
sudo nginx -t
sudo nginx -s reload
```

Для nginx в Docker выполни эти команды внутри его контейнера.
Из внешней сети проверь `http://ytd.bakabuka.com/` и
`https://ytd.bakabuka.com/`. После включения redirect в Gateway ожидаются
HTTP 301 и HTTPS 200; до redirect HTTP отдаёт приложение.

## TLS внутри кластера

Для завершения TLS upstream в Gateway путь HTTPS в выбранной схеме такой:

```text
Клиент HTTPS:443 → MikroTik dst-nat → домашний nginx HTTPS virtual host:443
  → HTTPS upstream MacBook:8443 → Docker TCP-прокси → NodePort:30443
  → Gateway HTTPS:8443 (TLS Terminate, Secret с сертификатом)
  → Service:80 → приложение HTTP:8000
```

Порт 8443 выбран для внутреннего HTTPS; для клиента остаётся стандартный 443.
HTTP продолжает идти через MacBook:8080. На домашнем nginx используются
`listen 443 ssl` и `proxy_pass https://192.168.30.37:8443`; оба участка
HTTPS защищены отдельными TLS-соединениями. Режим Gateway — `HTTPS` с `tls.mode: Terminate`,
а не `TLSRoute`: HTTP-маршрутизация выполняется после расшифровки в Gateway.

### 1. Сертификат и Secret

Если сертификат уже выпущен cert-manager по разделу Let's Encrypt выше,
Secret `ytd-tls` уже существует: пропусти ручной импорт и переходи к шагу 2.

Нужны сертификат с полной цепочкой и соответствующий приватный ключ.
Сертификат должен содержать нужные домены в SAN. Можно использовать готовый
сертификат с домашнего nginx либо получить новый у удостоверяющего центра.
Для нескольких поддоменов подходит `*.bakabuka.com`; он не покрывает
`bakabuka.com` и имена вида `a.b.bakabuka.com`.

Для сертификата только на `ytd.bakabuka.com` создай Secret:

```sh
kubectl -n ytd create secret tls ytd-tls \
  --cert=/ABS/PATH/fullchain.pem \
  --key=/ABS/PATH/privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

Подставь реальные пути; Secret должен находиться в namespace Gateway (`ytd`).
Не добавляй приватные ключи или YAML Secret с ключом в репозиторий.
Команда подходит и для обновления сертификата: после замены файлов повтори
её, Gateway Fabric подхватит изменение Secret. Перезапуск Deployment
приложения для этого не требуется. При ручном импорте обновление сертификата
на домашнем сервере само по себе не обновляет Secret в Kubernetes.

### 2. HTTPS listener в gateway.yaml

В `spec.listeners` сохрани существующий `http` и добавь второй listener:

```yaml
    - name: https-ytd
      hostname: ytd.bakabuka.com
      port: 8443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: ytd-tls
      allowedRoutes:
        namespaces:
          from: Same
```

Для wildcard-сертификата в Secret `ytd-tls` можно задать
`hostname: "*.bakabuka.com"` и подключать к этому listener маршруты других
поддоменов. Для отдельных сертификатов создай отдельный HTTPS listener
на том же порту 8443 для каждого домена, с уникальным `name`, конкретным
`hostname` и своим Secret. Используй одно `certificateRefs` на listener.

### 3. HTTPS NodePort в nginx_proxy.yaml

Полный вариант NginxProxy для двух портов:

```yaml
apiVersion: gateway.nginx.org/v1alpha2
kind: NginxProxy
metadata:
  name: ytd-proxy
  namespace: ytd
spec:
  kubernetes:
    service:
      type: NodePort
      externalTrafficPolicy: Cluster
      nodePorts:
        - port: 30080
          listenerPort: 80
        - port: 30443
          listenerPort: 8443
```

Этот пример предполагает переход HTTP listener на 80 для HTTP-01,
описанный выше. Если используешь ручной импорт или DNS-01 и оставил
HTTP listener Gateway на 8080, укажи здесь `listenerPort: 8080`.

### 4. Подключение HTTPRoute к HTTPS

В `ytd/httproute.yaml` замени `parentRefs` на:

```yaml
  parentRefs:
    - name: ytd-gateway
      sectionName: http
    - name: ytd-gateway
      sectionName: https-ytd
```

Это оставляет приложение доступным и через HTTP, и через HTTPS.
Для нового HTTPS-домена также добавь HTTPS parentRef в его HTTPRoute и
убедись, что hostname listener и SAN сертификата покрывают этот домен.
Примени после создания Secret:

```sh
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n ytd describe gateway ytd-gateway
kubectl -n ytd describe httproute youtubedl
kubectl -n ytd get svc ytd-gateway-nginx
```

Ожидаются `Programmed=True`, успешные условия обоих listeners и порты
`80:30080/TCP`, `8443:30443/TCP` у Service Gateway для варианта HTTP-01.

### 5. TCP-прокси HTTPS на MacBook

Существующий HTTP-прокси остаётся на 8080. Создай рядом с `compose.yaml`
файл `docker-tls.conf.template` со следующим полным конфигом nginx:

```nginx
events {}

stream {
    resolver 127.0.0.11 valid=5s ipv6=off;
    resolver_timeout 5s;

    map $remote_addr $tls_backend {
        default ${MINIKUBE_NODE}:30443;
    }

    server {
        listen 8443;
        proxy_pass $tls_backend;
        proxy_connect_timeout 5s;
        proxy_timeout 600s;
    }
}
```

Образ `nginx:1.28-alpine` в этой конфигурации имеет встроенный модуль stream.
Создай `compose.tls.yaml`:

```yaml
services:
  tls-proxy:
    image: nginx:1.28-alpine
    restart: unless-stopped
    ports:
      - "0.0.0.0:8443:8443"
    environment:
      MINIKUBE_NODE: ${MINIKUBE_NODE:-ytd}
      NGINX_ENVSUBST_FILTER: ^MINIKUBE_NODE$
      NGINX_ENVSUBST_OUTPUT_DIR: /etc/nginx
    volumes:
      - ./docker-tls.conf.template:/etc/nginx/templates/nginx.conf.template:ro
    networks:
      minikube:
        ipv4_address: ${MINIKUBE_TLS_PROXY_IP:-192.168.58.251}
```

Адрес `.251` должен быть свободен и принадлежать сети minikube. Если сеть
другая, добавь её свободный адрес в `.env` через `MINIKUBE_TLS_PROXY_IP`.
Оба контейнера используют сеть из основного `compose.yaml`.

```sh
docker compose -f compose.yaml -f compose.tls.yaml config --quiet
docker compose -f compose.yaml -f compose.tls.yaml up -d
docker compose -f compose.yaml -f compose.tls.yaml exec -T tls-proxy nginx -t
```

Теперь MacBook слушает HTTP на 8080 и TCP с TLS на 8443. Для запуска,
диагностики и остановки обоих прокси используй оба `-f`; например:

```sh
docker compose -f compose.yaml -f compose.tls.yaml ps
docker compose -f compose.yaml -f compose.tls.yaml logs --tail=100 tls-proxy
docker compose -f compose.yaml -f compose.tls.yaml down
```

### 6. Домашний nginx: HTTPS upstream для этих доменов

Используй полный virtual host из раздела «Один virtual host bakabuka.conf
для HTTP и HTTPS». В нём HTTP направляется на MacBook:8080, HTTPS — на
MacBook:8443, с сохранением Host и SNI. Установи клиентский сертификат
на основном сервере, проверь `nginx -t` и перезагрузи его конфигурацию.
Разреши основному серверу доступ к MacBook:8443. Настройки других сайтов
и общий listener через stream для этого варианта менять не требуется.

### 7. Проверка TLS

На MacBook проверь полный путь через Docker-прокси, сохранив SNI и hostname:

```sh
curl --max-time 15 --resolve ytd.bakabuka.com:8443:127.0.0.1 \
  https://ytd.bakabuka.com:8443/
```

С домашнего сервера повтори проверку, заменив `127.0.0.1` на IP MacBook.
Из внешней сети проверь `https://ytd.bakabuka.com/` на стандартном 443.
Ожидается HTTP 200 и успешная проверка сертификата. Одна только подстановка
`Host` при запросе `https://127.0.0.1` не проверяет нужный SNI.
Для сертификата собственной CA используй `curl --cacert /PATH/ca.pem`.

### 8. Перенаправление HTTP → HTTPS

После успешной проверки HTTPS убери `sectionName: http` из parentRefs
маршрута приложения, оставив `https-ytd`. Создай `http-redirect.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ytd-http-redirect
  namespace: ytd
spec:
  parentRefs:
    - name: ytd-gateway
      sectionName: http
  hostnames:
    - ytd.bakabuka.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            port: 443
            statusCode: 301
```

Добавь `http-redirect.yaml` в `kustomization.yaml`, выполни
`kubectl apply -k .`. Явный порт 443 нужен для внешнего адреса клиента;
listener Gateway использует внутренний порт 8443. Для других доменов
добавь соответствующие hostnames в этот redirect или создай отдельный.
Проверь:

```sh
curl --max-time 15 -I -H 'Host: ytd.bakabuka.com' http://127.0.0.1:8080/
```

Ожидается 301 и `Location: https://ytd.bakabuka.com/`.

### Wildcard-сертификат через DNS-01

Для автоматической выдачи и продления используй cert-manager с ACME Issuer
и DNS-01 solver своего DNS-провайдера. Это альтернатива HTTP-01 выше.
Для wildcard-сертификатов Let's Encrypt
требуется DNS-01. Этот способ не зависит от внешнего HTTP-проброса:
проверка выполняется через TXT-записи в авторитетной DNS-зоне.

После установки cert-manager и создания ClusterIssuer `letsencrypt-dns`
с учётными данными своего DNS-провайдера создай `Certificate` в namespace
`ytd` с `secretName: ytd-tls`, `dnsNames` для нужных доменов и
`issuerRef.kind: ClusterIssuer`, `issuerRef.name: letsencrypt-dns`.
Дождись `Ready=True` у Certificate, затем используй этот Secret в Gateway.
При переходе на cert-manager перестань вручную обновлять управляемый им Secret.
Конфигурация solver зависит от DNS-провайдера; ссылки на установку и DNS-01
приведены ниже. Для ручного импорта из шага 1 cert-manager не требуется.

## Конфигурация и креды shoplist

Для практики централизованного управления секретами есть отдельная
[лаборатория Vault + External Secrets Operator](VAULT.md): установка в minikube,
init/unseal, KV v2, Kubernetes auth, синхронизация и обновление кредов shoplist.
Этот вариант включается отдельно; инструкции ручного управления ниже
не нужно применять одновременно с синхронизацией ESO.

Манифесты приложения находятся в `shoplist/`. Deployment подключает
ConfigMap `shoplist-config` и Secret `shoplist-credentials` через `envFrom`:
каждый ключ становится переменной окружения контейнера. Оба ресурса
должны находиться в том же namespace `ytd`, что и Deployment.

В `shoplist/configmap.yaml` замени `EXAMPLE_CONFIG` на реальные имена
и значения несекретных переменных приложения. В `shoplist/secret.example.yaml`
`EXAMPLE_USERNAME` и `EXAMPLE_PASSWORD` — примеры, а не подтверждённые
имена переменных shoplist. Замени их на имена, ожидаемые приложением.
Можно добавить другие ключи: пароль БД, API-токен, параметры авторизации.
Для строковых значений ConfigMap используй кавычки, в том числе для чисел
и логических значений.

### Secret без пароля в файле

`stringData` содержит открытый текст, а `data` — base64, не шифрование.
Чтобы не сохранять значение в YAML и истории команд, введи имя ключа
(например, `POSTGRES_PASSWORD`), затем скрыто введи значение в терминале macOS (zsh):

Для этого варианта нужен `jq` (проверка: `command -v jq`). Если Secret ещё
не существует, один раз создай пустой ресурс:

```zsh
kubectl apply -f namespace.yaml
kubectl -n ytd create secret generic shoplist-credentials
```

Если Secret уже существует, не удаляй его и пропусти создание. Следующий блок
добавляет или обновляет один ключ, сохраняя остальные. Повтори его для каждого
нужного ключа:

```zsh
read -r 'secret_key?Ключ (например POSTGRES_PASSWORD): '
read -rs 'secret_value?Значение (скрытый ввод): '
printf '\n'
printf '%s' "$secret_value" |
  kubectl -n ytd create secret generic shoplist-credentials \
    --from-file="${secret_key}=/dev/stdin" \
    --dry-run=client -o json |
  jq -e '{data: .data}' |
  kubectl -n ytd patch secret shoplist-credentials \
    --type=merge --patch-file=/dev/stdin
unset secret_key secret_value
```

Например, чтобы задать три переменные в одном Secret `shoplist-credentials`:

1. Запусти блок выше, введи ключ `POSTGRES_USER` и значение пользователя БД.
2. Повтори блок, введи ключ `POSTGRES_PASSWORD` и пароль БД.
3. Повтори блок, введи ключ `API_TOKEN` и значение токена, если приложение
   поддерживает такую переменную.

Это примеры имён: используй именно те, которые ожидает приложение.
При повторном вводе существующего ключа обновляется только его значение.
Deployment уже подключает `shoplist-credentials` через `envFrom.secretRef`,
поэтому каждый добавленный ключ станет переменной окружения нового контейнера.
Пароли и токены не нужно добавлять в `shoplist/configmap.yaml`.

После ввода всех ключей примени манифесты и перезапусти приложение:

```sh
kubectl apply -k .
kubectl -n ytd rollout restart deployment/shoplist
kubectl -n ytd rollout status deployment/shoplist
```

Пароль не отображается при вводе; JSON передаётся напрямую между командами,
без сохранения файла. Не используй этот способ при включённом `set -x`,
который печатает значения переменных. Используется JSON merge patch:
меняется только введённый ключ, остальные сохраняются.
Не используй старый вариант `create --dry-run ... | kubectl apply -f -`
для последовательного добавления ключей: `apply` может удалить ключи,
которые были в предыдущем применении, но отсутствуют в новом.
Если так уже были потеряны ключи, введи их значения заново через блок с `patch`.
Проверить имена ключей без раскрытия значений:

```sh
kubectl -n ytd describe secret shoplist-credentials
```

Для обновления пароля повтори ввод и применение, затем перезапусти Deployment.
Это обновляет переменную приложения, но не меняет пароль в самой PostgreSQL.

Secret всё равно доступен пользователям с соответствующими правами Kubernetes.
По умолчанию Secrets хранятся в etcd без шифрования: для защиты нужны
ограничения RBAC и отдельно настроенное шифрование данных при хранении.
Подробнее: [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/).

### Альтернатива: локальный YAML

Если выбираешь хранение пароля в локальном файле, создай копию Secret:

```sh
cp shoplist/secret.example.yaml shoplist/secret.local.yaml
```

Заполни `shoplist/secret.local.yaml` реальными значениями в `stringData`.
Кодировать их в base64 вручную не нужно. Локальный файл исключён через
`.gitignore`, но это не защищает его содержимое на диске; шаблон сохраняй
без реальных паролей. Применяй в таком порядке:

```sh
kubectl apply -f namespace.yaml
kubectl apply -f shoplist/secret.local.yaml
kubectl apply --dry-run=server -k .
kubectl apply -k .
kubectl -n ytd rollout status deployment/shoplist
```

Главный `kustomization.yaml` включает приложения `ytd/` и `shoplist/`,
а также ConfigMap shoplist. Secret применяется отдельно: повторный
`kubectl apply -k .` не перезаписывает пароли значениями шаблона.
Если Secret ещё не создан, контейнер shoplist не запустится и покажет
`CreateContainerConfigError`.

После изменения ConfigMap или Secret перезапусти pod, чтобы контейнер
получил обновлённые переменные окружения:

```sh
kubectl apply -f shoplist/secret.local.yaml
kubectl apply -k .
kubectl -n ytd rollout restart deployment/shoplist
kubectl -n ytd rollout status deployment/shoplist
```

Для обновления только настроек команда применения Secret не требуется.
Эти креды передаются приложению; для скачивания образа из приватного
registry нужен отдельный Secret типа `kubernetes.io/dockerconfigjson`
и `spec.template.spec.imagePullSecrets`.

## Логи pod и Deployment

Найди pod приложения в namespace `ytd`:

```sh
kubectl -n ytd get pods
kubectl -n ytd get pods -l app=shoplist
```

Последние 100 строк и новые сообщения в реальном времени:

```sh
kubectl -n ytd logs ИМЯ_ПОДА --tail=100 -f
```

Имя pod меняется после пересоздания; можно обращаться через Deployment:

```sh
kubectl -n ytd logs deployment/shoplist --tail=100 -f
kubectl -n ytd logs deployment/youtubedl --tail=100 -f
```

Для Deployment с несколькими репликами собери логи по labels:

```sh
kubectl -n ytd logs -l app=shoplist --all-containers=true --prefix --tail=100 -f
```

После падения контейнера посмотри логи его предыдущего запуска:

```sh
kubectl -n ytd logs ИМЯ_ПОДА --previous --tail=100
```

Если в pod несколько контейнеров, укажи `-c ИМЯ_КОНТЕЙНЕРА`.
Когда контейнер вообще не запускается, проверь события pod:

```sh
kubectl -n ytd describe pod ИМЯ_ПОДА
```

Для другого namespace замени `ytd`. Остановить просмотр `logs -f` можно
через Ctrl+C, приложение при этом продолжает работать.

## Диагностика и ежедневный запуск

После создания профиль и параметры кластера сохраняются. Запусти Docker
Desktop, затем:

```sh
minikube start
minikube update-context
kubectl config use-context ytd
kubectl get nodes
docker compose up -d
```

Если включён TLS, последнюю команду замени на
`docker compose -f compose.yaml -f compose.tls.yaml up -d`.
Повторная установка Helm chart и применение манифестов после обычного
`minikube stop/start` не нужны. После `minikube delete` пройди установку
с начала, включая CRD, контроллер, приложение и TLS Secret.

| Симптом | Проверка и действие |
| --- | --- |
| `apiVersion not set`, `kind not set` для Compose | Используй `kubectl apply -k .`, Compose запускай отдельно через Docker. |
| `no matches for kind Gateway/HTTPRoute/NginxProxy` | Установи Gateway API CRD и Gateway Fabric до применения приложения. |
| `namespaces ytd not found` | Применяй через Kustomize; для отдельных файлов сначала примени namespace.yaml. |
| Конфликт IP при старте ноды | Проверь сеть Docker; прокси должны занимать свободные `.250` и `.251`, ноды — `.2–.4`. |
| HTTP 504 через NodePort | Проверь готовность Gateway и `externalTrafficPolicy: Cluster` у его Service. |
| HTTP 404 | Проверь Host, HTTPRoute hostnames, parentRefs и условия Accepted/ResolvedRefs. |
| TLS handshake или неверный сертификат | Проверь Secret, SAN, SNI, HTTPS listener и TCP-проброс обоих прокси. |
| HTTP 502/503 | Проверь readiness pod, Service selector/targetPort и EndpointSlice. |

```sh
kubectl -n ytd get gateway,httproute,svc,pods,endpointslices
kubectl -n ytd describe gateway ytd-gateway
kubectl -n ytd describe httproute youtubedl
kubectl -n ytd logs deployment/youtubedl --tail=100
kubectl -n ytd logs deployment/ytd-gateway-nginx -c nginx --tail=100
docker compose logs --tail=100 proxy
```

## Документация TLS

- [Завершение HTTPS в NGINX Gateway Fabric](https://docs.nginx.com/nginx-gateway-fabric/traffic-management/https-termination/)
- [SNI-маршрутизация без завершения TLS в nginx](https://nginx.org/en/docs/stream/ngx_stream_ssl_preread_module.html)
- [Установка cert-manager через Helm](https://cert-manager.io/docs/installation/helm/)
- [DNS-01 solver и поддерживаемые DNS-провайдеры](https://cert-manager.io/docs/configuration/acme/dns01/)
- [HTTP-01 через Gateway API](https://cert-manager.io/docs/configuration/acme/http01/)
- [ACME Issuer](https://cert-manager.io/docs/configuration/acme/)
- [Certificate и автоматическое продление](https://cert-manager.io/docs/usage/certificate/)
- [Типы проверок Let's Encrypt](https://letsencrypt.org/docs/challenge-types/)
