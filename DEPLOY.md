# Деплой Postiz на свой сервер

Продакшн-развёртывание через Docker Compose: готовый образ `ghcr.io/gitroomhq/postiz-app`,
Postgres, Redis и Temporal.

Предполагаемая топология: этот стек живёт на отдельной VM и отдаёт приложение
по обычному HTTP на приватный адрес, а домен и TLS-сертификат настраиваются на
другой VM с реверс-прокси. Поэтому в стеке нет ни прокси, ни выпуска
сертификатов — только приложение и его зависимости.

Файлы, которые за это отвечают:

| Файл | Что это |
| --- | --- |
| `docker-compose.prod.yaml` | продакшн-стек |
| `.env.production.example` | шаблон конфигурации |
| `Makefile` | команды: `init`, `up`, `logs`, `update`, `backup`, … |

`docker-compose.yaml` в корне репозитория — это официальный quickstart-файл, для
продакшна он не используется: там захардкожены пароли и `localhost`, наружу
открыты Temporal и отладочные порты, а том с базой Temporal анонимный
(данные теряются при пересоздании контейнера).

## 1. Что понадобится на VM

- Docker с плагином `compose` (проверка: `docker compose version`), `make`, `git`, `openssl`
- ОЗУ: **4 ГБ** для полного стека; на 2 ГБ — смотрите раздел «Экономный режим»
- Диск: от 20 ГБ (образы ~3 ГБ + база + загруженные медиафайлы)
- Сетевая связность с прокси-VM и знание приватного IP этой VM

## 2. Быстрый старт

```bash
cd ~/postiz-app                 # каталог с клоном репозитория
git fetch origin
git checkout claude/postiz-server-deployment-y10la4
git pull

make init                       # создаст .env и сгенерирует секреты
nano .env                       # заполнить MAIN_URL и POSTIZ_BIND
make check                      # проверка конфигурации
make up                         # запуск
make logs SERVICE=postiz        # смотреть первый старт
```

Первый запуск занимает 3–10 минут: контейнер накатывает схему базы
(`prisma db push`), поднимает бэкенд, фронтенд и воркер Temporal. Готовность
видно по логам и по `make ps` (статус `healthy`).

Проверить, что приложение отвечает, ещё до настройки прокси:

```bash
curl -I http://<приватный-IP>:4007
```

## 3. Что заполнять в `.env`

Обязательный минимум:

```dotenv
MAIN_URL=https://postiz.example.com   # публичный адрес на прокси, БЕЗ слеша на конце
POSTIZ_BIND=10.0.0.5                  # приватный IP этой VM, к которому ходит прокси
POSTIZ_PORT=4007
```

`MAIN_URL` — это именно тот адрес, который видит пользователь в браузере, то есть
`https://...`, хотя сама VM отдаёт открытый HTTP. Из него собираются
`FRONTEND_URL` и `NEXT_PUBLIC_BACKEND_URL`, по нему же строятся ссылки в письмах
и redirect URI для OAuth соцсетей — если он не совпадёт с реальным адресом,
логин и подключение каналов сломаются.

`JWT_SECRET`, `POSTGRES_PASSWORD` и `TEMPORAL_POSTGRES_PASSWORD` уже сгенерированы
командой `make init`. **Менять `JWT_SECRET` после запуска нельзя** — разлогинятся
все пользователи.

`DATABASE_URL`, `REDIS_URL`, `FRONTEND_URL`, `NEXT_PUBLIC_BACKEND_URL`,
`BACKEND_INTERNAL_URL`, `TEMPORAL_ADDRESS` и каталоги загрузок задавать не нужно:
`docker-compose.prod.yaml` собирает их из значений выше, поэтому пароль и домен
прописаны ровно в одном месте.

Набор сервисов выбирается через `COMPOSE_PROFILES`:

| Профиль | Что добавляет |
| --- | --- |
| `elasticsearch` | расширенный поиск по задачам Temporal (~1 ГБ ОЗУ) |
| `tools` | Temporal UI на `127.0.0.1:8080` (только через SSH-туннель) |

По умолчанию `COMPOSE_PROFILES=elasticsearch`.

## 4. Настройка на прокси-VM

Проксировать нужно на `http://<приватный-IP-postiz-VM>:4007`. Приложение отдаёт
на одном порту и фронтенд, и API (`/api`), и загруженные файлы (`/uploads`), так
что достаточно одного `location /`.

Пример для nginx:

```nginx
server {
    listen 443 ssl http2;
    server_name postiz.example.com;

    ssl_certificate     /etc/letsencrypt/live/postiz.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/postiz.example.com/privkey.pem;

    client_max_body_size 2G;      # в приложении лимит 2G, иначе видео не загрузится

    location / {
        proxy_pass http://10.0.0.5:4007;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;   # генерация через AI и загрузка видео долгие
    }
}
```

Для Caddy на прокси-VM хватит:

```caddy
postiz.example.com {
	encode zstd gzip
	request_body {
		max_size 2GB
	}
	reverse_proxy 10.0.0.5:4007
}
```

На стороне Postiz-VM порт стоит закрыть для всех, кроме прокси:

```bash
sudo ufw allow from <IP-прокси-VM> to any port 4007 proto tcp
```

## 5. Первый аккаунт

Откройте `MAIN_URL`, зарегистрируйте первый аккаунт — он становится владельцем
инстанса. После этого поставьте в `.env` `DISABLE_REGISTRATION=true` и выполните
`make restart`, чтобы посторонние не могли регистрироваться.

## 6. Экономный режим (2 ГБ ОЗУ)

Elasticsearch нужен Temporal только для расширенного поиска по задачам; с
Postgres 12+ Temporal умеет то же самое своими средствами. Отключается двумя
строчками в `.env`:

```dotenv
COMPOSE_PROFILES=
TEMPORAL_ENABLE_ES=false
```

Обе строки надо менять вместе — `make check` за этим следит. Экономия ~1 ГБ ОЗУ.

## 7. Подключение соцсетей

Ключи приложений вписываются в `.env` (секция «Social Media API Settings»),
после чего `make restart`. Redirect URI в настройках приложения на стороне
платформы — `MAIN_URL` + `/integrations/social/<провайдер>`, например
`https://postiz.example.com/integrations/social/linkedin`.

Добавлять можно любые переменные из документации Postiz: весь `.env` целиком
пробрасывается в контейнер, менять compose-файл для этого не нужно.

### VK

VK ID работает по OAuth 2.1 + PKCE, поэтому из настроек приложения нужен по сути
только его идентификатор:

```dotenv
VK_ID=53123456        # «ID приложения» из настроек VK ID
VK_SECRET=            # «Защищённый ключ», нужен не всем типам приложений
```

Имя переменной — именно `VK_ID` (не `VK_CLIENT_ID`): если её не задать,
Postiz соберёт ссылку авторизации с `client_id=undefined`, и VK её отклонит.

`VK_SECRET` («Защищённый ключ») в PKCE-потоке не участвует и отправляется, только
если переменная заполнена — начните с пустого значения и заполните её, если VK
будет отвечать на обмен кода ошибкой о недостающем `client_secret`. «Сервисный
ключ доступа» здесь не нужен вообще: он авторизует запросы без пользователя, а
`wall.post` публикует от имени владельца токена.

В настройках приложения на стороне VK (id.vk.ru → «Настройки» → «Платформы» →
«Веб»):

- **Базовый домен** — домен из `MAIN_URL`, например `postiz.example.com`;
- **Доверенный redirect URL** — `MAIN_URL` + `/integrations/social/vk`,
  например `https://postiz.example.com/integrations/social/vk`;
- права доступа приложения должны включать `wall`, `photos`, `video`, `docs`,
  `status` и `email` — Postiz запрашивает именно этот набор.

Токен VK ID живёт около часа, дальше Postiz обновляет его сам по refresh-токену,
так что сервер должен ходить в `id.vk.com` без ограничений.

## 8. Эксплуатация

```bash
make ps                      # состояние контейнеров
make logs                    # логи всего стека
make logs SERVICE=postiz     # логи приложения
make restart                 # перезапуск после правки .env
make update                  # обновление образов до последней версии
make backup                  # дамп базы + архив загрузок в ./backups
make restore FILE=backups/db-20260812-120000.sql.gz
make down                    # остановить (данные в томах сохраняются)
```

Обновление и откат: в `.env` есть `POSTIZ_IMAGE` и `POSTIZ_VERSION` — репозиторий
образа и тег. По умолчанию это `ghcr.io/gitroomhq/postiz-app:latest`; чтобы
обновления были предсказуемыми, поставьте конкретный тег (например `v1.47.0`) и
меняйте его осознанно. Перед `make update` полезно сделать `make backup` —
миграции базы накатываются автоматически при старте и назад не откатываются.

### Своя сборка

По умолчанию сервер крутит официальный образ, то есть код из `gitroomhq`, а не
из этого репозитория. Если в форке есть свои правки (например, фиксы VK), их
надо собрать:

```bash
make image     # собирает образ из текущей ветки и переписывает .env
make up
```

`make image` берёт тот же `Dockerfile.dev`, которым собирается официальный
релиз, тегает результат как `postiz-local:<хеш коммита>` и проставляет в `.env`
`POSTIZ_IMAGE=postiz-local` и `POSTIZ_VERSION=<хеш>`. Если рабочее дерево
грязное, к тегу добавляется `-dirty` — чтобы по тегу всегда было понятно, что
именно уехало в прод.

Откат — это просто другой тег: `POSTIZ_VERSION=<старый хеш>` и `make up`
(прошлые образы лежат локально, пока их не съест `docker image prune`). Вернуться
на официальный образ — `POSTIZ_IMAGE=ghcr.io/gitroomhq/postiz-app` и
`POSTIZ_VERSION=latest`.

Пока в `.env` стоит локальный образ, `make update` обновляет только Postgres,
Redis и Temporal и предупреждает об этом: приложение обновляется через
`make image`, а не из реестра.

**Сборке нужно ~4 ГБ ОЗУ и ~10 ГБ свободного диска.** Память — потому что
фронтенд собирается с `--max-old-space-size=4096`; на VM из раздела 6 (2 ГБ)
сборка упадёт по OOM. Диск — потому что образ ещё и распаковывается поверх
собранных слоёв, и место кончается уже под самый конец, после всей сборки.
Поэтому `make image` проверяет свободное место заранее и отказывается стартовать,
если его мало:

```bash
docker system df                              # что занимает место
docker builder prune -af                      # кеш сборок, обычно самый жирный
docker image prune -af                        # неиспользуемые образы
du -sh backups/*                              # старые бэкапы тоже накапливаются
```

Порог меняется через `make image IMAGE_MIN_FREE_GB=6`, а совсем отключается
через `make image FORCE=1`.

Если памяти или диска не хватает в принципе — собирайте на другой машине и
переносите образ:

```bash
# на машине посильнее
docker save postiz-local:<хеш> | gzip | ssh user@postiz-vm 'gunzip | docker load'
```

и затем прописать `POSTIZ_IMAGE`/`POSTIZ_VERSION` в `.env` на сервере вручную.

Бэкапы кладутся в `./backups` (каталог в `.gitignore`) — забирайте их с сервера,
локальная копия не спасёт от потери диска. Регулярный бэкап через cron:

```cron
0 3 * * * cd /home/user/postiz-app && make backup >> /var/log/postiz-backup.log 2>&1
```

Temporal UI (посмотреть, почему пост не опубликовался): добавьте `tools` в
`COMPOSE_PROFILES`, `make up`, затем со своей машины
`ssh -L 8080:127.0.0.1:8080 user@postiz-vm` и откройте `http://127.0.0.1:8080`.

## 9. Если что-то пошло не так

**Прокси отдаёт 502.** Проверьте с прокси-VM: `curl -I http://<IP>:4007`. Если
не отвечает — либо `POSTIZ_BIND` стоит на `127.0.0.1` (тогда контейнер слушает
только внутри своей VM), либо порт режет фаервол, либо приложение ещё стартует
(`make ps`, статус должен быть `healthy`).

**Логин не работает, после входа выкидывает обратно.** Почти всегда `MAIN_URL`
не совпадает с адресом в браузере (лишний слеш на конце, `http` вместо `https`,
другой поддомен). Исправьте и `make restart`.

**Приложение не поднимается, в логах ошибки Prisma.** Значит контейнер не видит
базу: проверьте `make ps` (у `postiz-postgres` должно быть `healthy`) и что
`POSTGRES_PASSWORD` в `.env` не меняли после первого запуска — том с базой хранит
старый пароль. Если пароль всё же нужно сменить, делайте это внутри Postgres, а
не правкой `.env`.

**Elasticsearch падает при старте.** Чаще всего не хватает ОЗУ или занижен
`vm.max_map_count`:

```bash
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-postiz.conf
```

Либо просто перейдите в экономный режим (раздел 6).

**Посты не публикуются.** Публикацией занимается Temporal: `make logs SERVICE=temporal`
и воркер в логах `postiz`. Убедитесь, что у VM верное время (`timedatectl`) —
расписание считается по нему.

**Конфликт имён контейнеров при старте.** Значит на VM уже запущен стек из
официального `docker-compose.yaml`. Остановите его: `docker compose -f docker-compose.yaml down`.

**Переезд с официального `docker-compose.yaml`.** Тома с данными переиспользуются,
если совпадают имя проекта, имя пользователя и базы. Пропишите в `.env`
`POSTGRES_USER=postiz-user`, `POSTGRES_DB=postiz-db-local` и тот пароль, который
был у старого стека (`postiz-password`, если вы его не меняли), и обязательно
перенесите старый `JWT_SECRET` — иначе сессии и подключённые каналы отвалятся.
Сначала `make backup` на старом стеке, потом переключение.

## 10. Безопасность

- Наружу с этой VM не смотрит ничего: 4007 открыт только для прокси-VM,
  а Postgres, Redis и Temporal живут во внутренних сетях Docker и портов на
  хост не публикуют — не публикуйте их «для удобства», Temporal на 7233 не
  имеет аутентификации.
- `.env` создаётся с правами `600` и в git не попадает — храните копию секретов
  отдельно, `JWT_SECRET` восстановить неоткуда.
- После создания своего аккаунта — `DISABLE_REGISTRATION=true`.
- Temporal UI доступен только с localhost, через SSH-туннель.
