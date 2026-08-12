# Деплой Postiz на свой сервер

Продакшн-развёртывание через Docker Compose: готовый образ `ghcr.io/gitroomhq/postiz-app`,
Postgres, Redis, Temporal и, опционально, Caddy с автоматическим HTTPS.

Файлы, которые за это отвечают:

| Файл | Что это |
| --- | --- |
| `docker-compose.prod.yaml` | продакшн-стек |
| `.env.production.example` | шаблон конфигурации |
| `deploy/Caddyfile` | конфиг реверс-прокси (профиль `caddy`) |
| `Makefile` | команды: `init`, `up`, `logs`, `update`, `backup`, … |

`docker-compose.yaml` в корне репозитория — это официальный quickstart-файл, для
продакшна он не используется: там захардкожены пароли и `localhost`, наружу
открыты Temporal и отладочные порты, а том с базой Temporal анонимный
(данные теряются при пересоздании контейнера).

## 1. Что понадобится на сервере

- Docker с плагином `compose` (проверка: `docker compose version`), `make`, `git`, `openssl`
- ОЗУ: **4 ГБ** для полного стека; на 2 ГБ — смотрите раздел «Экономный режим»
- Диск: от 20 ГБ (образы ~3 ГБ + база + загруженные медиафайлы)
- Домен с A-записью на IP сервера и открытые порты 80/443 — если хотите HTTPS

## 2. Быстрый старт

```bash
cd ~/postiz-app                 # каталог с клоном репозитория
git fetch origin
git checkout claude/postiz-server-deployment-y10la4
git pull

make init                       # создаст .env и сгенерирует секреты
nano .env                       # заполнить MAIN_URL, MAIN_DOMAIN, LETSENCRYPT_EMAIL
make check                      # проверка конфигурации
make up                         # запуск
make logs SERVICE=postiz        # смотреть первый старт
```

Первый запуск занимает 3–10 минут: контейнер накатывает схему базы
(`prisma db push`), поднимает бэкенд, фронтенд и воркер Temporal. Готовность
видно по логам и по `make ps` (статус `healthy`).

Дальше открывайте `MAIN_URL`, регистрируйте первый аккаунт — он становится
владельцем инстанса, — после чего поставьте в `.env`
`DISABLE_REGISTRATION=true` и выполните `make restart`, чтобы посторонние не
могли регистрироваться.

## 3. Что заполнять в `.env`

Обязательный минимум:

```dotenv
MAIN_URL=https://postiz.example.com   # ровно тот URL, по которому открывается Postiz, БЕЗ слеша на конце
MAIN_DOMAIN=postiz.example.com        # только домен, без https:// — нужен профилю caddy
LETSENCRYPT_EMAIL=you@example.com     # почта для уведомлений о сертификатах
```

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
| `caddy` | реверс-прокси с автоматическим Let's Encrypt на портах 80/443 |
| `elasticsearch` | расширенный поиск по задачам Temporal (~1 ГБ ОЗУ) |
| `tools` | Temporal UI на `127.0.0.1:8080` (только через SSH-туннель) |

По умолчанию `COMPOSE_PROFILES=caddy,elasticsearch`.

## 4. Варианты подключения снаружи

### Вариант A. Домен + HTTPS через Caddy (по умолчанию)

Ничего дополнительно делать не нужно: Caddy сам получит и будет продлевать
сертификат. Требования — A-запись домена уже указывает на сервер, порты 80 и 443
свободны и открыты в фаерволе:

```bash
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
```

Сам Postiz при этом слушает только `127.0.0.1:4007`, наружу он не торчит.

### Вариант B. На сервере уже есть nginx / Traefik

Уберите `caddy` из `COMPOSE_PROFILES` и проксируйте на `127.0.0.1:4007`.
Пример секции для nginx:

```nginx
server {
    listen 443 ssl http2;
    server_name postiz.example.com;

    ssl_certificate     /etc/letsencrypt/live/postiz.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/postiz.example.com/privkey.pem;

    client_max_body_size 2G;

    location / {
        proxy_pass http://127.0.0.1:4007;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
    }
}
```

`MAIN_URL` всё равно должен совпадать с внешним адресом (`https://postiz.example.com`).

### Вариант C. Без домена, по IP

```dotenv
MAIN_URL=http://203.0.113.10:4007
COMPOSE_PROFILES=elasticsearch
POSTIZ_BIND=0.0.0.0
```

Интерфейс и планировщик работают, но подключить соцсети не получится: OAuth
почти всех платформ требует `https://` в redirect URI. Это режим «посмотреть и
потрогать», для реальной работы нужен домен.

## 5. Экономный режим (2 ГБ ОЗУ)

Elasticsearch нужен Temporal только для расширенного поиска по задачам; с
Postgres 12+ Temporal умеет то же самое своим средствами. Отключается двумя
строчками в `.env`:

```dotenv
COMPOSE_PROFILES=caddy
TEMPORAL_ENABLE_ES=false
```

Обе строки надо менять вместе — `make check` за этим следит. Экономия ~1 ГБ ОЗУ.

## 6. Подключение соцсетей

Ключи приложений вписываются в `.env` (секция «Social Media API Settings»),
после чего `make restart`. Redirect URI в настройках приложения на стороне
платформы — `MAIN_URL` + `/integrations/social/<провайдер>`, например
`https://postiz.example.com/integrations/social/linkedin`.

Добавлять можно любые переменные из документации Postiz: весь `.env` целиком
пробрасывается в контейнер, менять compose-файл для этого не нужно.

## 7. Эксплуатация

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

Обновление и откат: в `.env` есть `POSTIZ_VERSION`. По умолчанию `latest`;
чтобы обновления были предсказуемыми, поставьте конкретный тег (например
`v1.47.0`) и меняйте его осознанно. Перед `make update` полезно сделать
`make backup` — миграции базы накатываются автоматически при старте и назад не
откатываются.

Бэкапы кладутся в `./backups` (каталог в `.gitignore`) — забирайте их с сервера,
локальная копия не спасёт от потери диска. Регулярный бэкап через cron:

```cron
0 3 * * * cd /home/user/postiz-app && make backup >> /var/log/postiz-backup.log 2>&1
```

Temporal UI (посмотреть, почему пост не опубликовался): добавьте `tools` в
`COMPOSE_PROFILES`, `make up`, затем со своей машины
`ssh -L 8080:127.0.0.1:8080 user@server` и откройте `http://127.0.0.1:8080`.

## 8. Если что-то пошло не так

**Не выпускается сертификат.** Смотрите `make logs SERVICE=caddy`. Обычно
причина одна из трёх: A-запись ещё не разошлась (`dig +short postiz.example.com`),
порт 80 занят другим веб-сервером (`sudo ss -tlnp | grep :80`) или закрыт
фаерволом. У Let's Encrypt есть лимит на количество попыток — сначала чините
причину, потом перезапускайте.

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

Либо просто перейдите в экономный режим (раздел 5).

**Посты не публикуются.** Публикацией занимается Temporal: `make logs SERVICE=temporal`
и воркер в логах `postiz`. Убедитесь, что у сервера верное время (`timedatectl`) —
расписание считается по нему.

**Конфликт имён контейнеров при старте.** Значит на сервере уже запущен стек из
официального `docker-compose.yaml`. Остановите его: `docker compose -f docker-compose.yaml down`.

**Переезд с официального `docker-compose.yaml`.** Тома с данными переиспользуются,
если совпадают имя проекта, имя пользователя и базы. Пропишите в `.env`
`POSTGRES_USER=postiz-user`, `POSTGRES_DB=postiz-db-local` и тот пароль, который
был у старого стека (`postiz-password`, если вы его не меняли), и обязательно
перенесите старый `JWT_SECRET` — иначе сессии и подключённые каналы отвалятся.
Сначала `make backup` на старом стеке, потом переключение.

## 9. Безопасность

- Наружу открыты только 80/443 (или 4007 в варианте C). Postgres, Redis и
  Temporal живут во внутренних сетях Docker и портов на хост не публикуют —
  не публикуйте их «для удобства», Temporal на 7233 не имеет аутентификации.
- `.env` создаётся с правами `600` и в git не попадает — храните копию секретов
  отдельно, `JWT_SECRET` восстановить неоткуда.
- После создания своего аккаунта — `DISABLE_REGISTRATION=true`.
- Temporal UI доступен только с localhost, через SSH-туннель.
