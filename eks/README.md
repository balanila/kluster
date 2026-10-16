# EKS через Terraform

Независимый от minikube вариант. Первый Terraform-этап (`eks/`) создаёт
VPC, две публичные подсети в разных AZ, Internet Gateway, EKS и managed node
group с автоматически созданной ASG. Второй (`eks/addons/`) устанавливает
Cluster Autoscaler и EBS CSI через Helm provider и небольшую PostgreSQL,
когда Kubernetes API уже доступен. У этапов отдельные state-файлы.
Приложения и внешний балансировщик пока не разворачиваются.

| Параметр | Значение |
| --- | --- |
| Регион по умолчанию | `eu-central-1` |
| Kubernetes | `1.35`, стандартная поддержка EKS |
| Ноды | `t3.micro`, x86_64, 2 vCPU / 1 GiB RAM |
| Min / начальный desired / max | `2 / 2 / 4` |
| Покупка EC2 | On-Demand |
| ОС | EKS-optimized Amazon Linux 2023 |
| Диск ноды | 20 GiB gp3, encrypted |
| CPU credits | Standard, без оплаты surplus credits |
| NAT Gateway | Нет |
| SSH | Не настроен |
| Доступ к API | Публичный с указанными CIDR + приватный для нод |

Типа `t3.mini` в EC2 нет. `t3.micro` соответствует ограничению 1 GiB.
Это очень тесная конфигурация: ОС, kubelet, VPC CNI и kube-proxy занимают
часть памяти. Обычный лимит VPC CNI для t3.micro также мал — четыре
Pod на ноду. Здесь для micro задан `maxPods: 5`, чтобы учесть третий
hostNetwork DaemonSet EBS CSI наряду с CNI и kube-proxy; количество доступных
Pod IP при этом не увеличивается (обычно остаётся два на ноду).
CoreDNS, EBS CSI controller и Autoscaler дополнительно занимают
место; два worker не гарантируют размещение всех приложений и контроллеров.
Реальные значения проверь через `kubectl describe nodes` после запуска.
Если будет тесно, можно явно выбрать `t3.small` (2 GiB) или `t3.medium`
(4 GiB) в tfvars. ARM не выбран, поскольку совместимость готовых образов
приложений с ARM не проверялась.

ASG ограничена четырьмя нодами. Обновления node group используют стратегию
`MINIMAL`: старая нода удаляется перед запуском замены, без добавления
surge-нод. На время обновления доступная ёмкость уменьшается на одну ноду.
Desired 2 — начальное значение; затем им управляет Autoscaler,
а последующий `terraform apply` его не сбрасывает.

## Перед запуском

Нужны Terraform >= 1.6, AWS CLI v2 и kubectl. AWS CLI должен быть настроен
на нужный аккаунт через профиль/SSO/переменные окружения. Не записывай
access keys в Terraform. IAM identity, запускающая первый этап, должна
иметь права на создание VPC, IAM, EKS, EC2 и ASG tags.

### Установить инструменты и выбрать AWS-профиль

Инструкции установки: [Terraform](https://developer.hashicorp.com/terraform/install),
[AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
[kubectl](https://kubernetes.io/docs/tasks/tools/). Проверка после установки:

```sh
terraform version
aws --version
kubectl version --client
aws configure list-profiles
```

Последняя команда перечисляет имена уже настроенных AWS-профилей.
Выбери профиль нужного аккаунта и укажи его для текущего терминала
(вместо `my-aws-profile` подставь имя из списка):

```sh
export AWS_PROFILE=my-aws-profile
aws sts get-caller-identity --query '{Account:Account,Arn:Arn}' --output json
```

`Account` — ID аккаунта, в котором Terraform создаст кластер. Сверь его
с Account ID в меню аккаунта справа сверху AWS Console. `Arn` показывает,
под кем сейчас выполняются команды; доступ к AWS проверяется этой командой.
План показывает предполагаемые операции, но не доказывает наличие прав
на создание ресурсов: их набор нужно сверить с администратором IAM.

Если входишь через IAM Identity Center (SSO), настрой профиль один раз:

```sh
aws configure sso --profile my-aws-profile
aws sso login --profile my-aws-profile
export AWS_PROFILE=my-aws-profile
```

В мастере SSO session name — произвольное локальное имя. Start URL и SSO
region возьми в AWS Console → IAM Identity Center → Dashboard/Settings:
AWS access portal URL и регион Identity Center. Если консоль недоступна,
эти два значения предоставляет администратор AWS; URL часто выглядит как
`https://d-xxxxxxxxxx.awsapps.com/start`. Регион SSO может отличаться от
региона EKS. Scopes оставь предложенные мастером, затем в браузере войди
и выбери выданные аккаунт и роль. CLI default region для этого проекта —
`eu-central-1`, default output можно оставить `json`.
[Подробности AWS SSO](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html).

Если уже используешь IAM access keys, для настройки профиля выполни
`aws configure --profile my-aws-profile`. Ключ создаётся в IAM → Users →
твой пользователь → Security credentials → Access keys; Secret access key
показывается только при создании. Не печатай и не сохраняй ключи в README,
tfvars или командах. Если секретная часть старого ключа потеряна, её нельзя
посмотреть повторно: требуется новый ключ и согласованная замена старого.

Для второго этапа используй AWS-профиль с IAM ролью/пользователем,
указанными в `cluster_admin_arn`. Это постоянный IAM ARN, например
`arn:aws:iam::123456789012:role/EksAdministrator`, а не временный
`arn:aws:sts::...:assumed-role/...` из `aws sts get-caller-identity`.
Автоматические Kubernetes-права создателю кластера не выдаются:
администратор задаётся явной EKS access entry.

### Где взять `cluster_admin_arn`

Это IAM identity, которой Terraform предоставит административный доступ
к Kubernetes. Она должна быть доступна тебе через AWS CLI; роль нод или
роль самого EKS control plane для этого не подходит.

```sh
aws sts get-caller-identity --query Arn --output text
```

Если ответ начинается с `arn:aws:iam::` и содержит `:user/`, скопируй его
целиком в `cluster_admin_arn`. Например:

```hcl
cluster_admin_arn = "arn:aws:iam::123456789012:user/debalan"
```

Если ответ выглядит как
`arn:aws:sts::123456789012:assumed-role/MyRole/session-name`, это временная
сессия. `MyRole` — имя роли между `assumed-role/` и следующим `/`.
Получить постоянный ARN роли вместе с её полным путём можно так:

```sh
aws iam get-role --role-name MyRole --query Role.Arn --output text
```

Подставь свой `MyRole`. Для SSO имя обычно начинается с `AWSReservedSSO_`;
команда та же, а возвращённый ARN может содержать путь
`role/aws-reserved/sso.amazonaws.com/...`. Копируй полный ARN из ответа,
не собирай его заменой `sts` на `iam`: так можно потерять путь роли.

В браузере: AWS Console → IAM → Roles → роль → Summary → ARN.
Для IAM-пользователя: IAM → Users → пользователь → Summary → ARN.
При `AccessDenied` на `iam:GetRole` попроси администратора показать ARN
именно твоей роли или открыть её страницу в IAM. Если роль ещё не создана,
администратор сначала создаёт её и настраивает возможность входа в неё;
строка-пример `EksAdministrator` в tfvars сама роль не создаёт.
ARN вида `arn:aws:iam::...:root` тоже не подходит — нужен IAM user или role.
[EKS access entries](https://docs.aws.amazon.com/eks/latest/userguide/creating-access-entries.html),
[команда get-role](https://docs.aws.amazon.com/cli/latest/reference/iam/get-role.html).

### Где взять `api_allowed_cidrs` и остальные значения tfvars

На машине, с которой будешь запускать kubectl и `eks/addons`, выполни:

```sh
curl -4 --fail --silent --show-error https://checkip.amazonaws.com
```

Это её внешний IPv4, например `198.51.100.25`. Добавь `/32`:

```hcl
api_allowed_cidrs = ["198.51.100.25/32"]
```

Адрес выше — пример; нужен ответ команды на твоей машине. При VPN включи
его до проверки. Если Terraform addons выполняется с другой машины/CI,
получи внешний адрес и там и добавь отдельный CIDR в список. Локальный IP
вида `192.168.x.x` для публичного API не подходит.

Остальные поля выбираются при создании, а не копируются из готового кластера:

| Поле | Откуда взять значение |
| --- | --- |
| `aws_region` | Код региона в переключателе AWS Console; по умолчанию оставь `eu-central-1` (Frankfurt). Это регион EKS, не SSO. |
| `cluster_name` | Придумай уникальное в аккаунте/регионе имя или оставь `ytd-eks`. Занятые имена: `aws eks list-clusters --region eu-central-1`. |
| `kubernetes_version` | Оставь `1.35` для текущей связки с Autoscaler. Доступность в регионе проверяется командой ниже. |
| `node_instance_type` | Оставь `t3.micro` для 1 GiB; если не хватает памяти, выбери разрешённый тип из `variables.tf`. |
| `postgres_storage_gib` | Выбери размер диска, по умолчанию 5 GiB. Это не ID существующего EBS-диска. |
| `vpc_cidr` | Необязательное поле: по умолчанию создаётся новая сеть `10.42.0.0/16`. Если планируешь VPN/peering, сверь её с домашними/VPN сетями и VPC: `aws ec2 describe-vpcs --region eu-central-1 --query 'Vpcs[].CidrBlock' --output text`. |

CIDR из примеров и ID `123456789012` не нужно переносить буквально.

Ниже команды для macOS/Linux из корня репозитория:

```sh
aws sts get-caller-identity
cp eks/terraform.tfvars.example eks/terraform.tfvars
```

В `eks/terraform.tfvars` замени `cluster_admin_arn` и `api_allowed_cidrs`.
CIDR — внешний IP машины, с которой запускаешь kubectl и второй Terraform
этап, например твой IP с `/32`; пример `203.0.113.10/32` нерабочий.
При смене IP сначала обнови CIDR через первый Terraform-этап.
Ноды обращаются к приватному endpoint, поэтому их публичные IP в этот
список добавлять не нужно.

Перед созданием проверь доступность выбранной версии в регионе:

```sh
aws eks describe-cluster-versions --region eu-central-1
```

Версия закреплена на 1.35 для совместимости с Autoscaler v1.35.0 / chart
9.54.0. При изменении minor согласованно обнови image, chart и проверку
в `addons/main.tf`. Политика `STANDARD` исключает платную extended support,
но по окончании стандартной поддержки AWS автоматически обновит control
plane: обновляй заранее также ноды, системные компоненты и Autoscaler.

## 1. Создать инфраструктуру

```sh
terraform -chdir=eks init
terraform -chdir=eks fmt -check -recursive
terraform -chdir=eks validate
terraform -chdir=eks plan -out=eks.tfplan
terraform -chdir=eks apply eks.tfplan
terraform -chdir=eks output configure_kubectl
```

Получить команду без кавычек Terraform можно через
`terraform -chdir=eks output -raw configure_kubectl`; скопируй её в shell.
Для значений по умолчанию:

```sh
aws eks update-kubeconfig --region eu-central-1 --name ytd-eks --alias ytd-eks
kubectl --context=ytd-eks get nodes
kubectl --context=ytd-eks -n kube-system get pods
```

VPC CNI, kube-proxy и CoreDNS устанавливаются EKS как начальные
self-managed addons. Их обновления Terraform не ведёт. EBS CSI Driver
и StorageClass устанавливаются вторым этапом после Autoscaler.

## 2. Включить автомасштабирование и PostgreSQL

Подготовь параметры второго этапа из outputs первого. Это несекретный JSON;
команда ниже для shell macOS/Linux:

```sh
terraform -chdir=eks output -json addons_tfvars > eks/addons/terraform.tfvars.json
terraform -chdir=eks/addons init
terraform -chdir=eks/addons validate
terraform -chdir=eks/addons plan -out=addons.tfplan
terraform -chdir=eks/addons apply addons.tfplan
kubectl --context=ytd-eks -n kube-system rollout status deployment/cluster-autoscaler
kubectl --context=ytd-eks -n kube-system logs -l app.kubernetes.io/instance=cluster-autoscaler --tail=100
kubectl --context=ytd-eks -n ytd rollout status statefulset/postgres
kubectl --context=ytd-eks -n ytd get pods,pvc,svc
```

Helm provider получает краткоживущий token через `aws eks get-token`;
локальный kubeconfig для него не нужен. AWS CLI использует текущий профиль,
который должен соответствовать `cluster_admin_arn`.
Если для первого этапа использовалась другая IAM identity, перед вторым
выбери профиль администратора через `export AWS_PROFILE=...` и проверь
`aws sts get-caller-identity`, как описано выше.

Autoscaler получает свою IAM роль через IRSA, с привязкой к одному
ServiceAccount. Изменять desired и удалять инстансы он может только у ASG,
помеченной тегами этого кластера. Теги ставятся на саму ASG явно, поскольку
теги managed node group на неё не распространяются.

Без второго этапа группа остаётся с desired 2 и заменяет потерянные ноды,
но сама не увеличивается из-за Pending Pod. После установки Autoscaler
масштабирует её в пределах 2–4 по невозможности запланировать Pod.
Это не правило «CPU > 80%»: для приложений нужны реальные CPU/memory
`requests`. HPA при необходимости настраивается отдельно. Если один Pod
требует больше ресурсов, чем вмещает t3.micro, добавление нод не поможет.

## PostgreSQL и подключение shoplist

Второй этап создаёт namespace `ytd`, StatefulSet `postgres` с одной
репликой, внутренний headless Service `postgres:5432`, два Secret и PVC
`postgres-data`. DNS БД — `postgres.ytd.svc.cluster.local`.
Образ закреплён на `postgres:17.11-bookworm`. Запрос ресурсов 100m CPU /
128 MiB RAM, лимиты 500m / 384 MiB; `shared_buffers=32MB`,
`max_connections=20`. Пул соединений приложения должен помещаться в этот
лимит с запасом для администрирования. Порт PostgreSQL наружу не публикуется.

Отдельный EBS gp3-диск по умолчанию 5 GiB, шифрование включено.
Размер задаётся `postgres_storage_gib` в первом tfvars и передаётся через
output во второй этап. После изменения размера повтори генерацию
`eks/addons/terraform.tfvars.json` и plan/apply второго этапа. Диск можно
расширять; уменьшение размера PVC не поддерживается.

EBS CSI получает отдельную IAM роль через IRSA и запускает один controller
для экономии ресурсов. Helm chart закреплён на 2.67.0 (driver 1.67.0).
У controller явно задан регион, у node DaemonSet включён hostNetwork:
ему не нужен отдельный Pod IP micro-ноды. Это Helm-установка драйвера,
параллельный managed EKS add-on `aws-ebs-csi-driver` устанавливать не нужно.

При первой инициализации пустого диска создаются БД `shoplist`, схема
`shoplist` и одноимённый пользователь без superuser. Администратор
`postgres` имеет отдельный пароль. Оба пароля генерирует Terraform;
`shoplist-credentials` получает только учётные данные приложения.
Пароли не печатаются в outputs, но **сохраняются в Terraform state**,
поэтому state второго этапа требует защиты и резервной копии.
Не заменяй random_password и не редактируй Secret для ротации: PostgreSQL
применяет POSTGRES_PASSWORD и init-скрипт только к пустому PGDATA.
Ротация требует согласованного `ALTER ROLE`, обновления Secret и restart
приложения. Vault/ESO в этом EKS-сценарии не настроены.

Для приложений подготовлен отдельный Kustomization `eks/apps/`:
он использует те же Deployment, Service и HTTPRoute и свой ConfigMap
shoplist с внутренним DNS БД. Namespace, БД и Secret принадлежат Terraform.
После установки общего Gateway `ytd-gateway` с HTTP listener `http` и
внешнего входа для EKS из следующего раздела:

```sh
kubectl kustomize eks/apps
kubectl --context=ytd-eks apply --dry-run=server -k eks/apps
kubectl --context=ytd-eks apply -k eks/apps
kubectl --context=ytd-eks -n ytd rollout status deployment/shoplist
```

Текущий minikube ConfigMap при этом не меняется. Образ shoplist и его
механизм миграций не изменяются; init создаёт пользователя/БД/схему,
но не таблицы приложения и не переносит домашние данные.

Проверка БД без вывода паролей и пример резервной копии:

```sh
kubectl --context=ytd-eks -n ytd logs statefulset/postgres --tail=100
kubectl --context=ytd-eks -n ytd exec postgres-0 -- pg_isready -U postgres -d shoplist
kubectl --context=ytd-eks -n ytd exec postgres-0 -- \
  pg_dump -U postgres -d shoplist -Fc > shoplist.dump
```

Dump содержит данные приложения: храни его вне Git в защищённом месте.
Автоматические backups и репликация не настроены. Один Pod и один диск —
это лабораторная БД с возможными перерывами при обслуживании/сбое ноды.
Аннотация запрещает Autoscaler выселять Pod БД при scale-down; от сбоев
или обновлений EKS это не защищает. EBS привязан к одной AZ: при потере
ноды замена для этого Pod нужна в той же AZ. Одна ASG на две AZ не
гарантирует такую ёмкость, поэтому восстановление иногда потребует ручного
вмешательства; при отказе всей AZ диск недоступен.

PVC защищён `prevent_destroy`, а StorageClass имеет `Retain`:
пересоздание Pod сохраняет данные, обычный Terraform destroy будет
заблокирован защитой PVC. Удаление namespace вручную эту защиту обходит.
Диск и данные нельзя удалять без отдельного решения и резервной копии.

## Домен с NS у внешнего провайдера

NS можно оставить у текущего провайдера. Будущий путь трафика:

```text
DNS у твоего провайдера → AWS NLB:80/443 → Gateway → Service → Pod
```

Домен указывает на endpoint балансировщика приложения, а не на
`cluster_endpoint` из Terraform: это адрес Kubernetes API. Публичные IP
worker также не используй как постоянную DNS-цель.

В этой конфигурации NLB ещё не создаётся. Для следующего этапа:

1. Установи AWS Load Balancer Controller с собственной IAM ролью и
   закреплённой совместимой версией. Это обычный EKS, не EKS Auto Mode.
   Policy JSON, создание IAM-роли и ServiceAccount описаны в
   [инструкции AWS](https://docs.aws.amazon.com/eks/latest/userguide/lbc-helm.html).
   Эта роль пока не создаётся Terraform проекта; `cluster_admin_arn`
   и роль нод вместо неё использовать не нужно.
2. Установи Gateway API CRD и NGINX Gateway Fabric после проверки
   совместимости выбранных версий с EKS 1.35.
3. Подготовь отдельный EKS overlay: общий Gateway и маршруты приложений
   сохраняются, Service Gateway публикуется как `LoadBalancer` через NLB
   с внешними портами 80/443. Существующий NginxProxy с NodePort и HTTP
   listener 8080 предназначен для minikube; без адаптации корневой
   `kubectl apply -k .` внешнего входа EKS не создаст.
4. После готовности балансировщика возьми его DNS name из
   `Service.status.loadBalancer.ingress[].hostname`. У DNS-провайдера создай
   `CNAME`, например `ytd.bakabuka.com → <NLB DNS name>` и отдельную запись
   для shoplist; wildcard CNAME допустим, но маршруты нужны каждому приложению.
5. Для корня `bakabuka.com` обычный CNAME обычно невозможен: потребуется
   ALIAS/ANAME или flattening у текущего DNS-провайдера. Альтернатива —
   заранее выделенные EIP для NLB и A-записи на них; текущий Terraform
   ни EIP, ни балансировщик не создаёт.

Публичные подсети уже имеют discovery-тег `kubernetes.io/role/elb=1`.
Это подготавливает сеть для internet-facing NLB, но не публикует приложения.
Для HTTPS можно завершать TLS на NLB с ACM либо в Gateway с cert-manager.
ACM DNS validation требует CNAME у текущего DNS-провайдера; для wildcard
cert-manager потребуется DNS-01 и доступ к API твоего DNS-провайдера.

### Где найти адрес NLB, DNS-провайдера и значения для TLS

Параметры для установки контроллера берутся из первого этапа:

```sh
terraform -chdir=eks output -raw cluster_name
terraform -chdir=eks output -raw vpc_id
terraform -chdir=eks output -json public_subnet_ids
aws sts get-caller-identity --query Account --output text
```

Регион — значение `aws_region` в твоём tfvars. При установке Load Balancer
Controller явно передай ему регион и VPC ID: доступ контейнеров к IMDS
в этой конфигурации ограничен. ARN его новой роли после создания находится
в IAM → Roles → эта роль → ARN или получается через `aws iam get-role`,
как описано выше. Policy ARN выдаётся при создании policy и доступен в
IAM → Policies → созданная policy → ARN.

После настройки контроллера и публикации Gateway найди Service:

```sh
kubectl --context=ytd-eks get services -A
kubectl --context=ytd-eks -n ytd get services -o wide
```

Нужна строка с `TYPE=LoadBalancer`, относящаяся к Gateway. Из её колонки
`NAME` возьми имя Service, а `NAMESPACE` — namespace. Для ожидаемого имени:

```sh
kubectl --context=ytd-eks -n ytd get service ytd-gateway-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[*].hostname}{"\n"}'
```

Если имя отличается, замени его на найденное. Пустой ответ или `<pending>`
означает, что адрес ещё не выдан: посмотри `describe service` и логи
AWS Load Balancer Controller. Второй способ: AWS Console → EC2 →
Load Balancers → нужный NLB → Details → DNS name. Сверь его с Service,
чтобы не использовать адрес чужого балансировщика. `cluster_endpoint`
из `terraform output` здесь не используется.

Кто обслуживает DNS-зону, проверь с локального терминала:

```sh
dig +short NS bakabuka.com
```

NS показывают авторитетные серверы. Открой панель провайдера, которому
они принадлежат, и раздел DNS records / управление зоной `bakabuka.com`.
Регистратор домена и DNS-провайдер могут различаться; если панель неизвестна,
посмотри настройки делегирования NS в аккаунте регистратора или уточни
у владельца домена, кто управляет зоной. Имя панели из самих NS не всегда
можно определить однозначно.

Для поддомена `ytd.bakabuka.com` создай запись типа CNAME: Name/Host — `ytd`
(либо полное имя, если так требует панель), Target/Value — DNS name NLB
без `http://`, порта и пути. Сохрани запись и проверь:

```sh
dig +short CNAME ytd.bakabuka.com
dig +short A ytd.bakabuka.com
```

Если панель предлагает ALIAS/ANAME для корня зоны, цель та же — DNS name
NLB; точное название функции зависит от провайдера. Статические EIP —
отдельно создаваемые ресурсы: их Allocation ID находятся в EC2 → Elastic
IPs. Они назначаются NLB при его создании; брать текущие IP из `dig` и
записывать их как постоянные A-записи нельзя.

Для TLS на NLB открой AWS Console → Certificate Manager (ACM) в том же
регионе, что NLB → Request certificate → Public certificate. Укажи свои
имена, например `bakabuka.com` и `*.bakabuka.com`, и DNS validation.
В созданном сертификате раздел Domains покажет CNAME name и CNAME value:
именно их добавь в DNS-панель и оставь для продления. Дождись `Issued`.
Certificate ARN скопируй из Details этого сертификата — он понадобится
при настройке TLS listener/аннотации Service. Пока NLB не настроен,
одного сертификата недостаточно для HTTPS.
[DNS validation ACM](https://docs.aws.amazon.com/acm/latest/userguide/dns-validation.html).

Для TLS в Gateway DNS API token создаётся в панели текущего DNS-провайдера,
обычно в API / Tokens, с правами на изменение записей нужной зоны.
Названия прав, Zone ID и формат Secret возьми из инструкции
[DNS-01 solver этого провайдера](https://cert-manager.io/docs/configuration/acme/dns01/).
Если нужен внешний webhook, его установка и формат ключей описаны на
странице самого webhook. Универсального токена AWS для стороннего DNS нет.
Токен хранится в Kubernetes Secret; не помещай его в README или tfvars.
Если у провайдера нет подходящего API/solver, для отдельных имён используй
HTTP-01 после публикации порта 80 или выбери DNS-провайдера с поддержкой API.

`docker-proxy.conf.template`, Compose, домашний nginx и MikroTik для пути
напрямую через AWS не нужны. Домашнюю сеть из AWS эта VPC не видит:
`POSTGRES_HOST=192.168.30.25` из текущего minikube ConfigMap потребовал бы
VPN/сети. Для EKS используй `eks/apps/` с описанной выше кластерной БД.

## Расходы и state

Оплачиваются EKS control plane, EC2, EBS нод и БД, публичные IPv4 и исходящий трафик;
позже также NLB и его трафик. Это не бесплатный кластер даже при минимальных
worker. NAT Gateway отсутствует: worker имеют публичные IPv4 для исходящих
соединений, но входящие SSH/NodePort из Интернета здесь не открыты.
CPU Standard после исчерпания кредитов ограничивает производительность.

Оба этапа по умолчанию используют локальный state. State, планы, локальные
tfvars и `.terraform/` исключены через `.gitignore`; это не шифрование.
Храни state в защищённом месте. Созданные `init` файлы
`.terraform.lock.hcl` следует коммитить. Перед командной/CI работой настрой
удалённый backend с шифрованием и блокировкой отдельно для каждого этапа.
Это отдельная настройка, а не существующий ресурс этого проекта:
S3 bucket name и регион возьми в AWS Console → S3 → Buckets после создания
bucket для state; key придумай разный, например `eks/infra.tfstate` и
`eks/addons.tfstate`. Создание backend и миграция локального state здесь
не выполняются. Параметры и порядок миграции описаны в
[инструкции Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3).
Если bucket ещё нет, в S3 → Create bucket выбери регион, уникальное имя,
включённый Block Public Access, шифрование и versioning; учётной записи
Terraform нужны отдельные права на этот bucket и блокировку. Для KMS
используй ARN выбранного ключа из KMS → Customer managed keys → ключ → ARN
и предоставь Terraform доступ к нему. До миграции локальные state находятся
в `eks/terraform.tfstate` и `eks/addons/terraform.tfstate`.

ID диска PostgreSQL для учёта Retain найди до удаления namespace:

```sh
kubectl --context=ytd-eks -n ytd get pvc postgres-data -o jsonpath='{.spec.volumeName}{"\n"}'
kubectl --context=ytd-eks get pv ИМЯ_PV -o jsonpath='{.spec.csi.volumeHandle}{"\n"}'
```

Во вторую команду подставь имя из первой. Результат `vol-...` можно найти
в AWS Console → EC2 → Volumes в регионе кластера. Эти команды только
читают идентификаторы; удалять volume для получения ID не требуется.

При удалении сначала реши судьбу данных PostgreSQL и сделай резервную
копию. Защиту `prevent_destroy` у PVC снимай только после явного решения
удалить БД. Убери созданные позднее Kubernetes LoadBalancer/Ingress и
дождись освобождения их AWS ресурсов. Затем выполни
`terraform -chdir=eks/addons destroy` и после него
`terraform -chdir=eks destroy`. Retain оставит EBS-диск БД за пределами
Terraform state: отдельно учти его сохранение/удаление и оплату.
Сначала нужен доступный кластер для удаления Helm/Kubernetes ресурсов;
обратный порядок оставит второй state без API.

## Источники

- [Спецификации EC2](https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html)
- [Поддерживаемые версии EKS](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
- [Cluster Autoscaler в EKS](https://docs.aws.amazon.com/eks/latest/best-practices/cas.html)
- [Совместимость версий Autoscaler](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/README.md)
- [Сетевые балансировщики EKS](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html)
- [EBS CSI в EKS](https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html)
- [Официальный образ PostgreSQL](https://hub.docker.com/_/postgres)
