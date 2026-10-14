# Сравнение сетевого пути shift-register и Padel ID

Read-only проверка 11.10.2026 по запросу владельца. Проверенный main
`emilsvifullin/shift-register-team`: `6d1ec845996c1ad01e8f7308b1cbaf3e056a8ab8`.
Никаких изменений другого проекта не выполнялось.

## Доказательства

- [`CNAME`](https://github.com/emilsvifullin/shift-register-team/blob/6d1ec845996c1ad01e8f7308b1cbaf3e056a8ab8/CNAME)
  задаёт `shiftregister.ru`. HTTPS GET/HEAD корня вернул HTTP200, `server: GitHub.com`.
  Это хостинг статического сайта, не hostname API на Vercel.
- [`src/supabase.js`](https://github.com/emilsvifullin/shift-register-team/blob/6d1ec845996c1ad01e8f7308b1cbaf3e056a8ab8/src/supabase.js)
  задаёт маршруты Vercel proxy и непосредственно проект Supabase. Один постоянный
  storageKey сохраняет сеанс при смене пути. WebSocket всегда прямой, обновление
  данных также использует polling.
- [`src/network-routes.js`](https://github.com/emilsvifullin/shift-register-team/blob/6d1ec845996c1ad01e8f7308b1cbaf3e056a8ab8/src/network-routes.js)
  проверяет `/auth/v1/health`, стартует второй probe через350ms, выбирает первый
  успешный, хранит свежесть60s и отодвигает отказавший путь на5min. GET/HEAD и
  password login допускают переключение после отказа; запись/refresh не
  повторяются автоматически после неопределённого ответа. Чтение тела ограничено
  сроком, а200 HTML не становится успешным JSON чтением приложения.
- Опубликованный `https://shiftregister.ru/src/network-routes.js` совпал побайтно
  с проверенным main: SHA256
  `9b1a15519e89cd5cdf83183e311d51246e86481e3f9959b203ca195e770d9ca5`.
  В опубликованном supabase.js оба маршрута тоже присутствуют.
- [`tests/network-routes.test.js`](https://github.com/emilsvifullin/shift-register-team/blob/6d1ec845996c1ad01e8f7308b1cbaf3e056a8ab8/tests/network-routes.test.js)
  воспроизводит отказ соединения, остановку тела ответа,502, отказ mutation без
  повтора, refresh без replay и отмену вызывающей стороны.

## Результат проверки на устройстве

Владелец проверил через МегаФон без VPN оба backend-адреса Shift Register:

- `https://shift-register-supabase-proxy.vercel.app/auth/v1/health`
- `https://rxosovinouuonwrrzigs.supabase.co/auth/v1/health`

**Оба не открываются.** Доступная страница GitHub Pages сама по себе не доказывает
свежую загрузку данных из backend; конкретное состояние кеша/сеанса браузера не
установлено. Поэтому это не подтверждённый рабочий сетевой путь, который можно
просто перенести в Padel. Проект Shift Register оставлен без изменений по прямому
указанию владельца; его DNS, код, настройки, данные и deployments не менялись.

Read-only DNS-сравнение через публичный резолвер на 11.10.2026:

| Host | Наблюдавшиеся A records |
|---|---|
| padel-id-gamma.vercel.app | 216.198.79.195, 64.29.17.195 |
| shift-register-supabase-proxy.vercel.app | 216.198.79.67, 64.29.17.67 |
| xnxhlfuncxyzdfdmqlkb.supabase.co | 172.64.149.246, 104.18.38.10 |
| rxosovinouuonwrrzigs.supabase.co | 172.64.149.246, 104.18.38.10 |
| xnxhlfuncxyzdfdmqlkb.functions.supabase.co | 172.64.149.246, 104.18.38.10 |

Доказательство: `ios/build/verification/network-host-comparison.json`. Это
снимок DNS, не обещание постоянных IP и не доказательство конкретной фильтрации
оператором. Проверка `--resolve` нового Padel hostname к адресу `.67` дала TLS/
health успех на компьютере (`shift-ip-host-check.json`), но не физическую приёмку.
DNS не переписывался на наблюдавшийся чужой IP; адреса не закреплены в приложении.

## Подготовленное решение для Padel ID

`api-padel.shiftregister.ru` указывает на Vercel CDN; пользователь подтвердил
отказ и этого имени без VPN. Сам CNAME не создаёт независимого серверного пути.
Статический GitHub Pages не исполняет Hono API/account service.

Padel использует серверный gateway-secret и защищённые RPC; клиент не может
безопасно получить этот секрет или заменить `/v1/*` прямым REST/Auth. Поэтому
подготовлены общий Hono API для Supabase Edge и fixed-origin verification relay.
[Официальная документация](https://supabase.com/docs/guides/functions/routing)
поддерживает REST API/Hono в одной функции с префиксом её имени.

По разрешению владельца опубликована `gateway`, сейчас ACTIVE version 4,
probe false / relay true. Relay обращается только к существующему Vercel API,
сохраняет его revision и не требует чтения/замены защищённого ключа.
Согласованность действующего Vercel/account/database secret проверена безопасным
неуспешным recovery для несуществующего адреса; аккаунты не менялись.
`account` read-only metadata показывает ACTIVE version 4; её не развёртывали.
Hosted миграции и Vercel env/deploy не менялись. Первоначальный version 1
transport probe и ожидание исходного ключа — исторические этапы.

Публичные строгие TLS-проверки gateway дали shallow/deep 200 `status: ok`,
`database: ok`, прежний revision; anonymous read 401. Пользователь подтвердил
**Wi-Fi без VPN работает, МегаФон без VPN не работает**. Альтернативный официальный
адрес `https://xnxhlfuncxyzdfdmqlkb.functions.supabase.co/gateway/v1/health?deep=1`
на компьютере дал 200 без redirect, на iPhone через МегаФон тоже недоступен.
Нельзя считать смену имени или совпадение DNS сетевым исправлением.

APIRouteSelector выбирает путь до отправки записи, хранит bounded cooldown и
не повторяет mutation после неоднозначного transport failure. Ручной retry
сохраняет тот же ключ. 401/403 не превращаются в повод обойти права через другой
сервер. Session/cache/outbox не зависят от hostname. HTTP redirects запрещены
до пересылки тела/credentials; health сверяет JSON и конечный URL.

Production fallback остаётся **пустым**. Не закрыта физическая доступность через
обе сети и граница доверенного caller IP: relay делит Vercel IP rate budget между
пользователями, независимый Edge без trust использует `unknown`. Не отключать
ограничения и не доверять клиентским XFF ради зелёного теста.

Отдельный secret-free Node/Caddy relay подготовлен и локально протестирован
Docker build/run. Он требует сервера с доступным HTTPS и физической проверки;
у владельца пока только домен. VPS/домен не покупались и дополнительный DNS не
менялся. Инструкции и ограничения: `server/deploy/README.md`.

## Последние локальные доказательства

- Node 22: 101 unit tests + typecheck passed.
- Generated gateway, frozen Deno: check и 6 runtime tests passed.
- Настоящий Supabase PG17/Auth/Edge Runtime: 74 SQL + 26 races + 21 full Auth
  E2E passed; 5 неприменимых smoke/SQL-adapter tests skipped.
- iOS 27 Release: 156 unit tests passed, включая routes/cancellation/redirect,
  revision/session guards, private collection refresh, icon state и push.
- Build URL gate: 4 Python tests passed; разрешён HTTPS origin либо явно
  проверенный полный `/functions/v1/gateway`, прямой REST/Auth недопустим.
- Docker relay: build, compose syntax, health/deep 200, anonymous 401,
  no-store/no-cookie checks passed. Это локальный запуск, не серверный deployment.
- CI workflow подготовлен для Edge generation, frozen Deno и actual local stack
  E2E; удалённый GitHub CI ещё не запускался.

Артефакты: `server-final-unit.log`, `server-relay-deadline-typecheck.log`,
`relay-deadline-deno-{check,test}.log`, `stack-*.log`, `edge-relay-final-live.json`,
`edge-relay-final-deployed-source.json`, `production-key-consistency.json`,
`relay-container-*` в ignored `ios/build/verification/`.
