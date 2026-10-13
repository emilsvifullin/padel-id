# Сетевая доступность — аудит кандидата 1.2.0

## Замер 13.10.2026 — причина на Wi-Fi установлена; исправление отложено

Замеры выполнены с Mac владельца напрямую через физический интерфейс, в обход
VPN: `curl --interface en0 --resolve <host>:443:<ip>`. Сначала домашний Wi-Fi
Алмател, затем точка доступа iPhone с мобильными данными МегаФон. Разделы ниже
написаны до этого замера; там, где они расходятся с ним, верен этот раздел.

**Алмател (Wi-Fi).** Блокировка по IP: TCP-соединение не устанавливается, имя
хоста и SNI не влияют.

| Адреса Vercel | Результат |
| --- | --- |
| `64.29.17.{3,67,131}`, `216.198.79.{3,67,131}`, `76.76.21.21` | не соединяется |
| `64.29.17.{1,65,129,193,195}`, `216.198.79.{1,65,129,193,195}` | 200, 0,15–0,3 с |

DNS роутера отдаёт для `padel-id-gamma.vercel.app` адреса `.3`, для
`api-padel.shiftregister.ru` — `.65`. Поэтому первое имя не работает, второе
работает. Оба имени закреплены за production проекта `padel-id` на Vercel.

**МегаФон (мобильные данные).** Те же адреса `.3/.67/.131` не соединяются. К
остальным TCP и TLS проходят, но дальше поведение зависит от имени:

| Имя (SNI) на рабочем адресе `216.198.79.65` | HTTP/2 | HTTP/1.1 |
| --- | --- | --- |
| `api-padel.shiftregister.ru` | 0 из 18, 0 байт за 7 с | 7 из 12, остальные зависают |
| `padel-id-gamma.vercel.app` | 200 | 200 |
| `vercel.com` | 200, 603 КБ | — |

DNS МегаФона отдаёт для `padel-id-gamma.vercel.app` адреса `.67`, то есть
заблокированные. Итог: на МегаФоне сейчас не работает ни одно из двух имён —
первое из-за адреса, второе из-за зависания после TLS. Механизм зависания
(фильтрация по имени) выведен из сравнения, провайдером не подтверждён.

Что ещё проходит на МегаФоне по HTTP/2 с телом 70 КБ и больше: Yandex Cloud
(`functions`, `apigw`, `containers`, `storage`), cloud.ru, Timeweb, Selectel,
Deno Deploy (`*.deno.dev`), GitHub Pages, основные сайты Vercel, Cloudflare,
Supabase и Netlify. Не проходит: `*.netlify.app`, проектный хост Supabase по
HTTP/2, `workers.dev`, render.com, AWS CloudFront.

**Решение владельца от 13.10.2026.** Работа без VPN исключена из условий
выпуска 1.2.0 и отложена до следующего этапа. Сборка 1.2.0 ходит на тот же
единственный адрес `https://padel-id-gamma.vercel.app`, что и 1.1.0, запасных
маршрутов нет; владелец пользуется приложением через VPN. Проблема без VPN
**не исправлена**.

Что осталось для следующего этапа:

- В коде есть выбор между несколькими адресами (`APIRouteSelector`,
  `PADELID_API_FALLBACK_URL` принимает несколько адресов через пробел). В
  выпущенной сборке список пуст, и этот путь не используется.
- Для Wi-Fi Алмател достаточно сделать основным `api-padel.shiftregister.ru`.
  На телефоне это не проверялось.
- Для МегаФона нужна точка входа на площадке из списка выше. Ретранслятор для
  Yandex Cloud Functions с доверенной передачей адреса клиента подготовлен и
  покрыт тестами в ветке `network/ingress-relay`; он не развёрнут и в выпуск
  не входит.

Дополнение11.10.2026: пользователь подтвердил, что `api-padel.shiftregister.ru`
также не работает безVPN. Это имя по-прежнему ведёт на Vercel; смена hostname
не решила отказ. По запросу владельца проверен работающий `shift-register-team`,
его опубликованный сайт и исходники; там есть выбор двух независимых маршрутов.
Подробности и подготовка одинакового gateway через Supabase Edge:
`shift-register-network-comparison.md`. Дальнейшие исторические формулировки
об отсутствии домена/ожидании custom hostname относятся к первоначальному аудиту.
Ещё одно исправление локального кандидата: deep health больше не использует
fail-open limiter, который мог вернуть `database:ok` при upstream503. Старый
production deep health поэтому не доказывает успех обращения к БД строго.

Проверено 10 октября 2026, 18:56–18:58 МСК (15:56–15:58 UTC). Кодовые выводы ниже относятся к опубликованной базе 1.1.0 (`b93723d`), изученной до параллельных локальных изменений кандидата. Это расследование существующей production-конфигурации, а не подтверждение исправления. Сетевой дефект остаётся обязательным незакрытым пунктом приёмки.

## Что установлено

- Пользователь подтвердил отказ на iPhone 17 Pro Max / iOS 27.0.1 в России: Алмател Цифра 1 (Wi-Fi) и МегаФон (мобильная сеть) без VPN; те же сценарии работают с VPN. Дополнительный реальный замер, переданный пользователем во время разработки 10.10.2026: Safari не загружает ни `/v1/health`, ни `/v1/health?deep=1` в обеих сетях без VPN; с VPN оба URL загружаются. Точный текст браузерной ошибки и время попыток ещё не получены.
- `ios/PadelID/Core/Networking/AppEnvironment.swift`: Release обращается к единственному API `https://padel-id-gamma.vercel.app`; override доступен только Debug. `DesignSystem/Components.swift` строит URL аватаров на том же API. Прямого обращения iOS к Supabase нет.
- Цепочка: iPhone → HTTPS/Vercel CDN → Hono в `dub1` → Supabase Auth, RPC, Storage и Edge Function `account`. Наличие шлюза само по себе не доказывает доступность его домена/IP из целевых сетей.
- `APIClient.execute` заменяет любой транспортный сбой на `APIError.offline`. Потеря DNS, TLS, маршрута, timeout и реальное отсутствие сети дают одинаковый текст. `Connectivity` проверяет доступный сетевой путь (`NWPathMonitor`), а не достижимость API. Скриншот не определяет конкретный слой отказа.
- HTTP-ошибка upstream в `server/src/upstream.ts` обычно становится структурированным `service_unavailable`, а не транспортным `network` клиента. Поэтому наблюдаемый текст повышает вероятность отказа до HTTP-ответа или клиентского timeout; это вывод по коду, не доказанная блокировка провайдером.

## Текущее удалённое состояние

Read-only GitHub CLI и Vercel connector; токены, тела запросов пользователей и значения secrets не читались/не выводились. Не выполнялись deploy, commit, push, публикация релиза, изменение DNS/firewall или account lifecycle.

| Проверка | Фактический результат | Ограничение |
| --- | --- | --- |
| GitHub releases | `v1.0.0` (09.10.2026 15:38:23 UTC), `v1.1.0` (10.10.2026 12:49:23 UTC); оба опубликованные, не prerelease | `1.2.0` — корректная следующая кандидатная версия на момент аудита |
| Последний production smoke | [run 38052919180](https://github.com/emilsvifullin/padel-id/actions/runs/38052919180), commit `b93723db3c71e9a3f28187c38ffd5d84c4f63a74`, success | Ubuntu CI, 2 tests passed / 17 skipped; account lifecycle и анонимная проверка, не весь social E2E и не российский iPhone |
| Production health | HTTPS 200, `status=ok`, commit `b93723db3c71e9a3f28187c38ffd5d84c4f63a74` | Только сеть текущего исполнителя |
| Deep health | HTTPS 200, `database=ok` | Проверяет RPC rate limiter; существующий health bucket обновляется. Не является полностью свободным от технических записей GET и не проверяет все Auth/Storage/Edge сценарии |
| HTTP/1.1 и HTTP/2 | Оба возвращают health 200 | Не подтверждает эти протоколы в Алмател/МегаФон |
| System resolver | `216.198.79.67`, `64.29.17.67` | Адреса CDN динамические; нельзя фиксировать их в приложении |
| HTTPS через каждый IP с сохранённым hostname/SNI | `/v1/health` 200; `/v1/me` без токена 401 `not_authenticated`; TLS verification не отключалась | Сеть текущего исполнителя, обычное анонимное обращение |
| `curl -6` | 200 через `::ffff:216.198.79.67` | IPv4-mapped адрес: нативная IPv6-доступность не подтверждена |
| UDP DNS (`dig`) | Локальный timeout | Ограничение этой среды/резолвера, не доказательство DNS-отказа в России |
| Vercel project | `padel-id`, ID `prj_vXX1ax3AjlMfW83jHp3rwWUsoI1X`, owner `team_d3mgGNpjDXKP40wD4Bnh07Ad`; latest production READY | Свежесть проверять перед поставкой |
| Project domains | Единственный configured domain `padel-id-gamma.vercel.app`, verified | Собственный домен сейчас не подключён |
| Deployment protection | password protection false; trusted IPs false; SSO `all_except_custom_domains` | Основной домен фактически отвечает публично; настройки не исключают региональные platform mitigations |
| Firewall config / active attack API | 404 `Seawall Config not found` | Не удалось получить полноценный отчёт правил; нельзя утверждать, что все блокировки исключены |
| Runtime logs, последние 30 min | Только 5 событий группы `info` на момент чтения | Малый временной срез; старый отказ пользователя не покрыт. Запрос 1h был отклонён по retention, 30m доступен |

Пример корреляции успешного обращения: `x-request-id=09562fbc-1d62-4989-a328-1fdaeb166fb8`, `x-vercel-id=fra1::dub1::7nb47-1791647804204-d88fde886239`, 15:56:45 UTC. Это не trace неуспешной попытки пользователя.

## Первопричина и отдельный дефект

**Первопричина VPN-зависимости пока не доказана.** Возможны DNS-фильтрация, блокировка домена/SNI/IP или маршрута, различия IPv4/IPv6, platform mitigation по IP, либо медленные ответы и клиентский timeout. Изменение DNS, домена или хостинга должно следовать измерениям, а не подменять их.

Реальный Safari-замер сузил локализацию: отказ не ограничивается iOS APIClient или регистрацией. Shallow health не обращается к Supabase, поэтому недоступность этого URL в браузере указывает прежде всего на путь устройства к публичному Vercel endpoint либо platform edge. Неисправность Supabase не объясняет одновременно недоступный shallow health. Это локализация участка, а не доказательство конкретного типа фильтрации.

Отдельно подтверждён несогласованный бюджет: клиент задаёт 15 секунд для mutations и 8 секунд для refresh; шлюз допускает 12 секунд на отдельный upstream request, 20 секунд на `account`, плюс последовательные rate-limit RPC. Signup выполняет limit → account creation → password grant. Клиент способен закончить ожидание до подтверждения созданного аккаунта и получения recovery key. Это реальный риск неопределённого исхода операции, но данных о том, что именно он вызвал отказ без VPN, нет. Лечение VPN-дефекта увеличением timeout не допустимо. Для самостоятельной правки этого риска нужны согласованный общий server deadline, recoverable/idempotent account flow и воспроизводящий тест медленного upstream; нельзя автоматически повторять signup или refresh после неопределённого транспортного исхода.

## Конкретный следующий замер на iPhone

Во всех четырёх сочетаниях записать время МСК до секунды, версию приложения/build, фактическую версию iOS, оператора, состояние Wi-Fi/LTE/5G и VPN. Не сбрасывать сетевые настройки и не переустанавливать приложение до первого сравнения. Состояние iCloud Private Relay / Limit IP Address Tracking записать, поскольку Safari и приложение могут идти разными маршрутами.

1. В приватной вкладке Safari открыть [shallow health](https://padel-id-gamma.vercel.app/v1/health). Ожидается JSON `status: ok`, а не страница входа/проверки. Сохранить показанный JSON либо точный текст браузерной ошибки и время. Не использовать deep health для массовых повторений.
2. Открыть [анонимный endpoint](https://padel-id-gamma.vercel.app/v1/me). Ожидается JSON с `not_authenticated` (HTTP 401 — корректный ответ, подтверждающий доступность API, не отказ связи).
3. В приложении выполнить вход в уже существующий аккаунт и загрузить профиль/игры. Зафиксировать, какой именно шаг не прошёл и примерно сколько секунд он ждал. Не создавать новые аккаунты на каждой диагностической попытке.
4. Повторить без изменения данных: Алмател без VPN; Алмател с VPN; МегаФон без Wi-Fi и без VPN; МегаФон с VPN. Первые и третьи строки сейчас не пройдены по данным пользователя.
5. Одновременно с одним отмеченным воспроизведением разработчик проверяет Vercel access/runtime/firewall события внутри retention. Наличие HTTP-ответа/`x-request-id` локализует отказ дальше transport; отсутствие записи функции само по себе не исключает блокировку на CDN/firewall и требует edge traffic проверки.

| Сеть | VPN | Safari health | Safari me | Вход/профиль/игры | Время и evidence |
| --- | --- | --- | --- | --- | --- |
| Алмател Цифра 1 Wi-Fi | off | Не загружается, shallow и deep (пользователь) | Ожидается | По исходному тесту отказ | Точный текст/время ожидаются |
| Алмател Цифра 1 Wi-Fi | on | Оба URL загружаются (пользователь) | Ожидается | По исходному тесту работает | Точный текст/время ожидаются |
| МегаФон LTE/5G, Wi-Fi off | off | Не загружается, shallow и deep (пользователь) | Ожидается | По исходному тесту отказ | Точный текст/время ожидаются |
| МегаФон LTE/5G, Wi-Fi off | on | Оба URL загружаются (пользователь) | Ожидается | По исходному тесту работает | Точный текст/время ожидаются |

Если Safari также не получает HTTP без VPN, на компьютере в том же домашнем Wi-Fi, затем через hotspot МегаФона, собрать DNS/default и независимый resolver, TLS/SNI, HTTP/1.1/2, IPv4/IPv6. Компьютерный замер помогает определить слой отказа, но не заменяет iPhone. IP получать заново; `curl --resolve` сохраняет hostname и проверку TLS. Не применять `-k`, ATS exceptions, plaintext HTTP или клиентский доступ к Supabase для обхода отказа. [Официальный Vercel диагностический репозиторий](https://github.com/vercel-support/vercel-connect-debug) сначала просмотреть; результат содержит сетевые/IP-сведения, публиковать только после очистки и отдельного разрешения владельца. Самостоятельная отправка support-сообщений не выполнена.

## Доступная инфраструктура и подготовленный путь исправления

Дополнительное read-only обследование после Safari-замера: Vercel team `emilsvifullin1` имеет **ноль собственных доменов**, два проекта (`padel-id`, `shift-register-supabase-proxy`) и только `*.vercel.app` aliases. Публичная Padel primary отвечает 200 из сети исполнителя. Aliases `padel-id-emilsvifullin1.vercel.app`, `padel-id-git-main-emilsvifullin1.vercel.app` и текущий deployment hostname возвращают HTTP 302 protection; замена primary на них сломает публичный доступ. Второй проект не обслуживает Padel API (`/v1/health` возвращает 404); его нельзя использовать как replacement gateway. Оба Supabase проекта ACTIVE_HEALTHY в `eu-west-1`; у Padel единственная Edge Function `account`, она не является публичным полным API. Доступного независимого owned gateway hostname не обнаружено.

DNS конфигурация primary: Vercel `misconfigured=false`. Адреса во время дополнительной проверки менялись: system resolver и Cloudflare DoH дали `216.198.79.3` / `64.29.17.3`, Google DoH — `.195` в тех же сетях CDN. Это разные ответы внешних резолверов вне целевых сетей, не установленная ошибка DNS. В приложении нельзя фиксировать выбранный CDN IP. Vercel рекомендует получать точные A/CNAME из карточки конкретного добавляемого домена; новый домен ещё не выбран, поэтому полученный для primary CNAME нельзя считать готовой настройкой будущего домена. [Официальные требования DNS](https://vercel.com/kb/guide/a-record-and-caa-with-vercel).

Подготовлены два конкретных пути с сохранением аккаунтов и API:

1. **Проверка собственного hostname на существующем Hono gateway.** Нужен принадлежащий владельцу домен и DNS-доступ, затем подключение отдельного API-subdomain к `padel-id` с HTTPS. Проверить shallow health в Safari на обеих сетях offVPN до смены Release URL. Если собственный hostname работает стабильно, проверить все authenticated сценарии и перевести `AppEnvironment.productionAPI` на него. Этот путь помогает при hostname/DNS фильтрации, но не обещает обойти блокировку общего CDN IP.
2. **Независимый HTTPS origin для того же Hono приложения.** Если Vercel path остаётся недоступен, нужен доступный владелец/хостинг с Node 22 и доменом; существующие `server/src/dev-server.ts` / build запускают весь API вне Vercel, без переноса базы и изменения пользовательских данных. Секреты provision серверно через защищённый hosting environment, не через репозиторий/чат; проверить origin→Supabase Auth/RPC/Storage/account и реальный iPhone→origin. Предпочтительно обслуживать API напрямую на этом origin, чтобы не зависеть от заблокированного клиентского CDN; перед сменой URL проверить forwarding/client-IP rate limits и отсутствие public caching. Смена `dub1` на другую function region не меняет входной Vercel CDN edge и сама по себе не решает этот участок.

Оба пути требуют реального домена либо hosting target и отдельного разрешения на инфраструктурную поставку; существующих ресурсов для независимого hostname в подключённых аккаунтах не найдено. Покупка домена, deployment, изменение DNS и protection не выполнялись. Публичные сообщения на площадках Vercel описывают похожие случаи в России, но официального подтверждения текущей блокировки конкретного Padel hostname этими операторами нет. Не используются как доказательство первопричины.

## Решение по результатам замера

| Подтверждённый слой | Конкретное исправление | Что нужно от владельца/сети |
| --- | --- | --- |
| DNS домена `vercel.app`; HTTPS с корректным SNI/IP доступен | Проверенный собственный API-домен с валидным сертификатом; испытать домен на обеих сетях перед сменой production URL | Принадлежащий владельцу домен, DNS-доступ и разрешение подключения/публикации. Домена в проекте сейчас нет |
| Домен/SNI фильтруется, собственный hostname проходит по тому же пути | Собственный домен после реального сравнительного теста | Домен/DNS-доступ; финальный iPhone результат |
| IP/CDN/маршрут Vercel не проходит | Разместить существующий Hono API на реально доступном origin или проверенном front door, сохранив server-side доступ к Supabase и общий API-контракт | Хостинг/account и разрешение инфраструктурной поставки; тест из обеих сетей. Один CNAME на тот же заблокированный IP не решает IP-фильтрацию |
| Vercel HTTP 403/challenge | Узко исправить конкретное правило/ложное срабатывание по подтверждённому trace, сохранив protections | Доступ к firewall traffic и точное время отказа. Не отключать DDoS/весь firewall |
| Только приложение; Safari API доступен | Снять `URLError.code` + ограниченные `URLSessionTaskMetrics` (DNS/connect/TLS/response durations) и проверять провайдерный путь приложения | Diagnostic build/экспорт отчёта и реальный iPhone. Не логировать URL query/body/Authorization/email или токены |
| Backend 5xx или время > client deadline | Исправить конкретный upstream/общий deadline и recovery семантику операции | Коррелированный gateway trace; тесты замедленного upstream. Не считать это доказательством устранения внешней фильтрации |

Для front door важно сохранить `Authorization`, исходный method/body и `Idempotency-Key`, не кэшировать private ответы, не делать redirect cross-origin с потерей bearer, корректно получать доверенный client IP для текущего rate limiting, не раскрывать gateway secret. Vercel [предупреждает о потере traffic visibility и проблемах кеша/latency при внешнем reverse proxy](https://vercel.com/kb/guide/cloudflare-with-vercel); Cloudflare не является доказанным решением для целевых операторов. Поэтому такой шаг требует проверенного сетевого результата и тестов, а не установки CDN по предположению.

## Окончательная приёмка

После подтверждённой инфраструктурной правки: Release IPA на iPhone, VPN off, обе целевые сети; signup/recovery-key, вход/refresh, профиль/аватар, статистика, игры, чаты и уведомления; переключение Wi-Fi↔мобильная сеть и восстановление соединения, отсутствие дублей mutations. Новые функции проверяются только после их реализации, не заявляются существующими по этому аудиту. После этого повторить VPN on как regression и записать build/commit нового production. Успешный curl/CI не закрывает эту приёмку.

## Источники

- [Vercel connectivity troubleshooting](https://vercel.com/kb/guide/troubleshooting-connectivity-issues): сравнение сетей, DNS и диагностика с affected network.
- [Vercel IP blocking troubleshooting](https://vercel.com/kb/guide/how-to-resolve-ip-blocking-issues): различение timeout без HTTP и firewall HTTP-response.
- [Apple URLSessionTaskMetrics](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics) и [TLS timing](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/secureconnectionstartdate): доступные transport measurements.
- [Vercel DDoS mitigation](https://vercel.com/docs/vercel-firewall/ddos-mitigation): platform protections требуют отдельной проверки, отсутствие project config не доказывает их отсутствие.
- Код: `AppEnvironment.swift`, `APIClient.swift`, `APIError.swift`, `Connectivity.swift`, `Components.swift`, `server/src/api.ts`, `server/src/upstream.ts`, `server/vercel.json`, `.github/workflows/production-smoke.yml`.

## Netlify Free diagnostic probe — 12 October 2026

The owner authorized publishing an isolated read-only diagnostic project and
created/verified a Free account. Published deep-health URL:
https://padel-id-network-probe.netlify.app/v1/health?deep=1 . Six unauthenticated
hosted HTTPS checks passed with normal system certificate validation: health
and deep health 200; POST health, /v1/me, default function route and arbitrary
query 404, without redirects or cookies. Deep response is deliberately
`status: configuration_required`, `mode: network_verification`,
`upstream_status: ok`, `database: ok`; this cannot be selected as a production
API route. Evidence: `ios/build/verification/netlify-probe-hosted-verification.json`.

The owner then confirmed on the actual iPhone without VPN: **Almatal Wi-Fi
works; MegaFon mobile data does not load the URL**. Thus this experiment has not
solved mobile connectivity. The exact DNS/IP/TLS/network mechanism remains
unproven; it is not evidence that every service on the provider is inaccessible.
The owner additionally confirmed that both Yandex and apple.com open in Safari
through MegaFon with Wi-Fi and VPN fully disabled. General browser connectivity
therefore works; the failures concern the tested API addresses. This still does
not establish a particular filtering, DNS or TLS mechanism.
Only the new diagnostic project was published; previews remain private. The
existing production API, Vercel/Supabase configuration, DNS and existing secrets
were not changed. Paid VPS remains declined; no new paid resource was ordered.
