# Текущая работа: Padel ID 1.2.0

Обновлено 12.10.2026. Рабочая копия `/Users/emilsvifullin/Developer/Padel ID`.
Пользователь подтвердил весь релиз 1.2.0, включая три подготовленные настоящие
Home Screen icons с Лайм по умолчанию. Shift Register изучали только read-only;
его проект, DNS, конфигурация и данные не изменены.
Новые Release27 units 168 / 168 и Community 18 / 21 прошли; Release26 и targeted
chat UI27 ещё выполняются. Units164 / focused3 / 3 обеих OS исторические.
Все failed UI cases покрыты успешными focused retries; нового полного 32 / 32
нет. IPA d56bc исторический после новой ChatModel правки; production доставка и физическая приёмка
остаются незавершёнными.

## Разрешения и сохранность

Последнее явное поручение пользователя: завершить production-релиз 1.2.0 сейчас.
Разрешены необходимые Git/release/deployment операции и production migrations/API
после резервирования и CI. Доступность через МегаФон без VPN пользователь вынес
за текущий scope; это отдельная незавершённая задача, а не gate этой публикации.
Production migrations/API/release ещё не выполнены; backup готов, branch 6d26f72
и PR 3 опубликованы, предыдущий Backend CI прошёл. PADELID_GATEWAY_SECRET не менять;
Shift Register, его конфигурацию и данные не трогать. Владелец явно согласовал выпуск 1.2.0 с уведомлениями внутри приложения.
APNs отложен на отдельный этап; shipping push NO — согласованное ограничение
этого релиза, а не ожидающее решение или gate публикации.
Ранее отдельно разрешены и выполнены только Supabase gateway verification
и isolated Netlify health probe. Новый production release ещё не опубликован;
исторические разрешения 1.1.0 не используются вместо нового поручения 1.2.0.

## Сеть и действующий API

Production revision `b93723db3c71e9a3f28187c38ffd5d84c4f63a74`. На iPhone пользователя
без VPN существующий Vercel API и `api-padel.shiftregister.ru` не открываются через
Алмател/Megafon; `vercel.com` работает. Конкретный механизм DNS/IP/SNI не доказан.

Supabase gateway ACTIVE version 4 — fixed-origin relay к прежнему API, без
копирования секрета. Strict TLS shallow/deep health 200, anonymous me 401;
production revision сохранена. Пользователь подтвердил Wi-Fi без VPN, но Megafon
не работает, включая официальный functions.supabase.co hostname. Production
fallback iOS пустой; новый путь не принят как сетевое исправление.

Согласованность Vercel/account/SQL secret проверена запросом recovery случайного
несуществующего адреса с неверным recovery key: ожидаемый invalid_recovery 403
после secret guard, без изменения аккаунтов. Account ACTIVE version 4 проверена
read-only, не развёртывалась. Fail-open health сам по себе не доказывал бы secret.

Пользователь подтвердил, что оба API Shift Register тоже не открываются через
Megafon без VPN. Доступность GitHub Pages страницы не доказывает свежий backend
запрос; кеш/маршрут браузера не установлен. Не закреплять CDN IP в клиенте/DNS.

Node/Caddy full API и relay подготовлены локально, Docker relay build/health
проверены. Внешнего сервера нет: у пользователя только домен; платный сервер он явно отклонил, VPS не покупали.
Relay агрегирует upstream IP budgets; нельзя доверять пользовательскому XFF или
ослаблять rate limits. Новый ingress требует доступного хостинга, проверенной
границы caller IP и физической приёмки. См. `server/deploy/README.md`.

Отдельный Netlify read-only probe опубликован по явному разрешению:
[health/deep](https://padel-id-network-probe.netlify.app/v1/health?deep=1).
Пользователь зарегистрировался и разрешил CLI auth; Free $0 подтверждён в UI,
платный сервер он отклонил. Site `2df11cca-1f71-4826-9a84-5c5977cd086f`, deploy
`6acbf908b35357bcd95b784d`. Public доступ открыт только этому новому probe,
previews остаются private. Bundle содержит только health и два pure helpers,
без app API/mutations/учётных данных. Production API/DNS/Supabase/Vercel/secrets
не изменены; это проверочный endpoint, не рабочая замена API приложения.

Локально 4 probe + 22 relay regressions и offline bundling passed; hosted strict-TLS
проверки 6/6 passed без redirects/cookies, `netlify-probe-hosted-verification.json`:
GET health shallow/deep 200, configuration_required/network_verification,
upstream_status: ok / существующий b93723; deep database: ok, shallow database not_checked.
POST health, me, default function URL и arbitrary query 404.
Пользователь подтвердил на физическом iPhone без VPN: Алмател Wi-Fi работает,
МегаФон mobile data URL не загружает. Probe не решил мобильную доступность,
production fallback остаётся пустым. Точный сетевой механизм не доказан; этот
результат не доказывает отказ всех сервисов Netlify. Яндекс и apple.com на том же
iPhone через МегаФон без Wi-Fi/VPN открываются: общий мобильный интернет работает.

## Реализация

Native SwiftUI пять вкладок, общие темы и настоящие alternate icons; социальные
чаты/группы/лента/подписки/privacy/reports; закрытые игры, приглашения, waitlist,
weekly timezone series; тренировки и четыре формата турниров; реальный каталог
клубов/кортов/карты/фото/admin и verified external booking. Рейтинг и outbox
обычных результатов сохранены. Private feed/comments/events не кешируются на
диск; списки обновляют bounded canonical visited window. Inbox и Conversations
теперь сохраняют посещённое окно до 150 строк при автообновлении/polling, вместо
возврата к первой странице. after_id=0 больше не отклоняется числовой валидацией;
route regression сначала воспроизвёл 400, затем прошёл после исправления. APNs client/private
queue/HTTP2 provider/worker/build gates реализованы, flag NO до настоящего Apple
provisioning/key/worker/device acceptance.

Последние дополнения:

- Десять безусловных анимаций в шести файлах теперь учитывают Reduce Motion;
  физический VoiceOver/Reduce Motion acceptance остаётся незавершённым.

- Публичные qualifications/about только подтверждённого тренера, реальное
  расписание и запись; свои события/история, ближайшая принятая будущая
  тренировка/турнир на Главной.
- Редактирование времени/условий открытого события сохраняет участников,
  использует metadata_version, защищает от stale overwrite и уведомляет
  участников. Score409 перезагружает канонический счёт/версию перед исправлением.
- Исправление публикации после определённого 4xx меняет idempotency key только
  при изменении payload; неопределённый retry сохраняет payload/key.
- Moderation показывает только актуальное содержимое конкретной жалобы, без
  доступа ко всей чужой переписке; удалённое содержимое не удерживается.
- Avatar Storage теперь private с live-session/visibility/owner operation guards;
  API передаёт bearer в authenticated Storage. Signed links/copy/move/list
  запрещены. Клиент очищает прежний image cache; gateway avatar path не дублируется.
  Старый клиент использовал anonymous API image URL и persistent cache, прежний
  сервер public Storage; нужен согласованный порядок обновления и cache audit.

## Последние исправления перед production

ChatModel защищён от позднего poll после подтверждённой отправки и от поздних
ответов после отзыва доступа. Release27 Community: 18 declarations / 21 case
executions PASS; полный optimized Release27: 168 / 168 PASS, без fail/skip.
`unit-chat-concurrent-fixed-27-summary.json`, `unit-chat-concurrent-all-27-summary.json`.
Полный Release26 168 и targeted chat UI27 ещё выполняются; их успех не заявлен.
Предыдущие units 164 и focused icons/chat3 / 3 каждой OS — исторические до этой правки.

Новая миграция `20261012180722_group_owner_account_cleanup.sql` при удалении
аккаунта владельца передаёт игровую группу детерминированному активному
незаблокированному участнику. Если преемника нет, группа архивируется; данные
остальных участников сохраняются. Service-only операции сериализованы.
Свежий полный локальный SQL: 87 / 87 PASS; реальные новые races: 3 / 3 PASS.
`group-owner-full-sql-final.log`, `group-owner-concurrency-final.log`;
новая guarded concurrency проверка включена в CI. Локальная цепочка — 25 миграций,
11 новых после исходных 14 hosted; production apply ещё не выполнен.

Защищённый production backup готов. Branch head 6d26f72 и PR 3 опубликованы;
Backend CI 6d прошёл 107 units / 83 SQL / 27 races, Node E2E 23 pass +5 skip и
Edge health. Это CI до последней миграции/ChatModel правки, новый integrated CI
нужен. Исходный Release 5f3 прошёл с units 164 и IPA 3.8 MB; draft не опубликован
и требует замены. Исходная GUI matrix ещё выполняется. Local IPA d56bc и manifest
127 относятся к прошлому app source, новый текущий артефакт ещё не проверен.
Финальный CLI dry-run подтверждает ровно 11 неприменённых миграций, без seeds/roles.
Production API остаётся b93723; nonsecret minimum build 3 staged, работающий старый
API не изменён. Shared secret сохранён. Уведомления внутри приложения входят
в 1.2.0; APNs и МегаФон без VPN отложены по явному решению владельца.

## Текущие результаты после устранения трёх пробелов

`EventEditDraft` сохраняет локальные правки при HTTP 409. Пользователь явно
выбирает keepDraft/useLatest; серверная версия обновляется без молчаливой потери
черновика. Профиль открывает `Route.myEvents`. Новости клуба используют прежние
posts с фильтром club_id, атрибуцией клуба и проверкой актуальных прав администратора.
Добавлена миграция `20261012073216_club_news_feed.sql`: локальная цепочка теперь
содержит 25 миграций, одиннадцать новых для 1.2.0. Hosted база не изменена.

| Проверка | Фактический результат | Доказательство |
|---|---|---|
| Полный backend unit | 107 / 107 passed | club-news-backend-full-unit.log |
| SQL в rollback/savepoint изоляции | 83 / 83 passed; данные 78 таблиц и fingerprint секрета сохранены | club-news-backend-full-sql-isolated.log, club-news-backend-* |
| Реальные Node и Edge E2E | Каждый: 23 passed, 5 skipped | club-news-backend-node-e2e.log, club-news-backend-edge-e2e.log |
| Прежний Release unit26 / unit27 до concurrency fix | Каждый: 164 / 164 PASS, 0 failed / 0 skipped, exit 0 | unit-chat-feedback-current-{26,27}-summary.json, .xcresult/log |
| Release unit26 / unit27 до ChatView fix | Каждый: 163 / 163 passed; historical | unit-draft-club-news-current-{26,27}-summary.json |
| Первый targeted UI27 новых требований | 4 passed, 1 failed из 5; отказ при первом вводе title до 409 | ui-draft-club-news-current-27-summary.json |
| Предыдущий event409 UI27 после wait helper fix | 0 passed / 1 failed; второй title edit после keepDraft, поле вне viewport | ui-event-draft-observed-27.xcresult/log |
| Прежний event409 UI27 после scroll helper fix | 1 / 1 PASS, 0 failed / 0 skipped, 158.180 s; historical | ui-event-draft-scroll-27-summary.json, ui-event-draft-scroll-27.xcresult/log |
| Current event409 UI27 с native button query | 1 / 1 PASS, 0 failed / 0 skipped; TEST SUCCEEDED, exit 0, 128.801 s | ui-event-draft-button-27-summary.json, ui-event-draft-button-27.xcresult/log |
| Прежний event409 UI26 после scroll helper fix | FAILED: isEnabled прочитан у Other wrapper вместо кнопки | ui-event-draft-scroll-26.xcresult/log |
| Current event409 UI26 с button query | 1 / 1 PASS, 0 failed / 0 skipped; TEST SUCCEEDED, exit 0, 108.138 s | ui-event-draft-button-26-summary.json, ui-event-draft-button-26.xcresult/log |
| Current build gates | API URL: 4 / 4 PASS; push/profile: 5 / 5 PASS | *-gates-current.log |
| Последний full UI26 | 32 total: 31 passed / 1 failed / 0 skipped, exit 65; wrapper query defect; corrected focused case PASS, whole bundle remains failed | ui-draft-club-news-full-26-summary.json, ui-draft-club-news-full-26.xcresult/log |
| Последний full UI27 после трёх дополнений | 32 total: 29 passed / 3 failed / 0 skipped, exit 65; historical до ChatView fix; все три failed cases затем покрыты focused PASS | ui-draft-club-news-full-27-summary.json, ui-draft-club-news-full-27.xcresult/log, ui-draft-club-news-full-27-devices.json, ui-draft-club-news-full-27-content-size.json |
| Players27 без сна Mac | 1 / 1 PASS, 0 failed / 0 skipped, exit 0, 167.885 s | ui-players-awake-27-summary.json, ui-players-awake-27.xcresult/log |
| Chat poll/send regression | RED 13 / 14 → GREEN 14 / 14, Release27; 16 case invocations / 14 declarations | unit-chat-send-poll-{red,fixed}-27-summary.json, .xcresult/log |
| Прежний focused icons/chat26 / 27 до concurrency fix | Каждый: 3 / 3 PASS, 0 failed / 0 skipped, exit 0 | ui-chat-icons-completion-{26,27}-summary.json, .xcresult/log |
| Иконки 24pt и HomeAX26 / 27 | Каждый: 2 / 2 PASS; визуально обе OS без наложения, SpringBoard показывает три реальных дизайна | ui-icon-native-size-final-{26,27}.xcresult/log |
| Прежний full UI27 retry | TEST INTERRUPTED, exit 75 после новых требований; не PASS | ui-final-current-full-27.xcresult/log |

Первоначальный SQL run: 77 passed, 6 failed — исторический отказ изоляции.
Корректный rollback/savepoint run 83 / 83 сохранил исходные данные 78 таблиц и
fingerprint локального секрета. В targeted UI27 прошли Account, две news и score409.
Event-edit остановился до 409: видео подтвердило задержку наблюдения введённого
текста, правильный фокус и отсутствие autocorrect. Исправлен только test helper:
после typeText он ждёт до 15 секунд точного contains, затем выполняет прежний
строгий assert; повторного ввода нет. Этот `ui-event-draft-observed-27` завершился
0 passed / 1 failed на втором title edit после keepDraft: lazy Form уже прокручен
примерно на 71%, title расположен выше viewport. AX evidence подтвердил, что
черновик не потерян. Helper теперь вызывает
scrollIntoView(element(eventEdit.title), searchBelow:false) перед require, сохраняя
wait 15s и точные assertions. `ui-event-draft-scroll-27` завершился TEST SUCCEEDED,
exit 0: 1 passed / 0 failed / 0 skipped, 158.180 s. Проверены сохранённый видимый
title после 409, явный review, повторная корректировка и точные две PUT операции
с version/title/location assertions. Прежний независимый
`ui-event-draft-scroll-26` FAILED по wrapper query; текущий button-query target
прошёл, подробнее ниже. Current API build
gates 4 / 4 и push/profile gates 5 / 5 PASS (`*-gates-current.log`).
Full26 `ui-draft-club-news-full-26` завершился exit 65: 32 total, 31 passed / 1 failed / 0 skipped.
Единственный отказ — XCTAssertFalse «Review is required before a rebased submission»
для eventEdit.save.isEnabled. Видео `event-edit-review-enabled-full-26-68-frame.png`
подтвердило: настоящий Save серый/disabled, review виден, локальный draft сохранён.
Лог показал Any query, разрешённый как Other wrapper вместо кнопки. Это test-only
query defect: три обращения к Save теперь используют app.buttons[eventEdit.save].
Строгий disabled assert и exact две PUT assertions сохранены. Старый target
`ui-event-draft-scroll-26` failed по той же wrapper query. Corrected focused test
`ui-event-draft-button-26` TEST SUCCEEDED, exit 0: 1 passed / 0 failed / 0 skipped,
108.138 s. Он покрывает единственный failure, но прежний full26 bundle остаётся
31 passed / 1 failed; нового полного 32 / 32 PASS пока нет.

Последний full UI27 `ui-draft-club-news-full-27` завершился exit 65:
32 total, 29 passed / 3 failed / 0 skipped. Отказы:

- `testAppearanceOffersThemesAndAllPreparedIcons`: кнопка «Графит» disabled
  после alert; отказ на ожидании selected, line 177, UIKit ещё pending.
- `testChatRequiresServerConfirmationAndRetriesSameSubmission`: элемент не найден
  за 10 секунд; воспроизведён poll/send feedback defect; исправление прошло текущий UI retry.
- `testPlayersSearchAndProfile`: timeout синтеза drag. Журнал питания показывает
  Clamshell Sleep в 11:36:18, DarkWake в 11:51:36 и Wake в 11:52:42;
  drag начался в 11:36:20.100 и timeout зарегистрирован в 11:51:36.205
  (ошибка 11:53:33.83). Это конкретное свидетельство влияния сна Mac;
  повтор `ui-players-awake-27` с предотвращением сна прошёл без изменения assertions:
  1 / 1 PASS, exit 0, 167.885 s.

Доказательства: `ui-full-27-host-power.log`, `ui-full-27-players-activities.json`.
Players repeat принят как 1 / 1 PASS; полный исторический bundle остаётся 29 / 32.
Chat feedback исправлен: poll обновляет loadError, а не очищает sendError;
неподтверждённая 503 отправка сохраняет feedback и retry identity. Scoped Release27
regression прошёл RED 13 / 14 → GREEN 14 / 14; privacy test имеет три аргумента
401 / 403 / 404, поэтому 14 declarations соответствуют 16 case invocations.
Артефакты: `unit-chat-send-poll-red-27` и `unit-chat-send-poll-fixed-27`.
Прежние полные optimized Release units26 / 27: каждый 164 / 164 PASS,
0 failed / 0 skipped, exit 0 (`unit-chat-feedback-current-{26,27}-summary.json`).

Icon failure в старом full27 произошёл на ожидании charcoal selected (line 177),
а не при tap: UIKit ещё завершал смену после alert, test ждал 10 секунд и не
проверял enabled. Исправлен только test: до перехода Home он до 30 секунд ждёт
selected && enabled и обрабатывает поздний SpringBoard alert. Продуктовый код
иконок не изменён. Focused runs `ui-chat-icons-completion-{26,27}` завершились каждый 3 / 3 PASS,
0 failed / 0 skipped, exit 0. Проверены настоящая смена иконки и три дизайна Home
Screen, возврат к Лайм по умолчанию и cold relaunch; chat 503 retry с тем же key
и подтверждённым сообщением; chat member profile context. Длительности (s):

| Runtime | Icons | Chat 503 retry | Member context |
|---|---:|---:|---:|
| iOS26 | 284.104 | 140.598 | 62.900 |
| iOS27 | 360.415 | 161.186 | 88.249 |

Доказательства: `ui-chat-icons-completion-{26,27}-summary.json`, `.xcresult/log`.
Все ранее упавшие отдельные UI cases покрыты успешными focused проверками:
event button 26, icons/chat обеих OS, Players27 без сна. Исторические full26
31 / 32 и full27 29 / 32 остаются failed; свежий full 32 / 32 с текущим
ChatModel не выполнялся. Полные Release units и targeted UI подтверждены.
Visual review27 подтверждён: свежие SpringBoard screenshots показывают
Лайм → Графит → Мяч → Лайм; настройки с AX-extra-large читаемы без перекрытий.
Доказательство: `ui-chat-icons-completion-27-visual/manifest.json`.
Физическая приёмка установленной production-сборки остаётся отдельной.
Последние focused button-query targets 26 / 27 прошли каждый 1 / 1;
UI27 `ui-event-draft-button-27`: 128.801 s, exit 0, 0 failed / 0 skipped.
Snapshot `event-edit-button-27-attachments/EDA6D4CB-0DF5-4E34-B804-8FAE0C310C06.png`
проверен основным и visual агентом: review при AX-extra-large читаем,
кнопки переносятся без наложения, Save серый и disabled. Точный draft и строгие
assertions подтверждены тестом. Последний full27 был скомпилирован до этих
test-only button query/snapshot additions; это доказательство относится к исходникам до нового ChatView fix.
Две actual clones: iOS 27.0, accessibility-extra-large, доказательства
`ui-draft-club-news-full-27-devices.json` и `ui-draft-club-news-full-27-content-size.json`.
IPA 69667 и его manifest исторические; исторический shipping artifact указан ниже.
Полная текущая UI matrix ещё не принята.

Исторический unsigned archive до ChatView fix: `archive-draft-club-news-local.log`, ARCHIVE SUCCEEDED.
IPA `ios/build/verification/PadelID-1.2.0-draft-club-news-local-unsigned.ipa`, 3734938 bytes,
SHA256 `69667ee2ec70bd95d88c290e531ec3938c5490c8b5f5a7b69247e1c49a6c5fca`.
`ipa-draft-club-news-local-verification.log`: IPA OK 1.2.0(3).
`ipa-draft-club-news-local-source.json`: 127 app source hashes совпадали с исходниками до ChatView fix;
signed=false, published=false; этот IPA исторический.
Исторический shipping archive до concurrency fix `PadelID-chat-feedback-local.xcarchive`:
`archive-chat-feedback-local.log`, ARCHIVE SUCCEEDED, ENABLE_TESTABILITY=NO.
Unsigned IPA `ios/build/verification/PadelID-1.2.0-chat-feedback-local-unsigned.ipa`,
3739714 bytes, SHA256
`d56bc2f36c93dc5c3cf724c0d1094c9f27de111a1c3b714aa0758377a017c148`.
`ipa-chat-feedback-local-verification.log`: verify-ipa exit 0, IPA OK 1.2.0(3).
`ipa-chat-feedback-local-source.json`: 127 app source hashes; относительно 69667
изменён только ChatView. Signed=false, published=false. Предыдущие IPA исторические.
Shipping push NO, fallback empty. Полная текущая UI matrix, signed physical
acceptance и production publication пока не выполнены. APNs delivery отложена
по явному решению владельца; уведомления внутри приложения входят в выпуск.
МегаФон без VPN исключён владельцем из текущей поставки; исправление отложено.

## История подтверждённых проверок до последних требований

Ignored evidence: `ios/build/verification/`.

- Текущий полный Node 22 unit run: 104 tests / 7 files passed,
  `server-cursor-final-unit.log`; включает 62 gateway tests с after_id=0 regression.
  TypeScript build и generated Edge build (12 modules) passed,
  `server-edge-cursor-final-build.log`; Deno check + 6 runtime tests passed,
  `edge-cursor-final-check.log`, `edge-cursor-final-test.log`.
- Чистая actual local Supabase цепочка 23 migrations и 79 SQL tests passed:
  `stack-final-reset.log`, `stack-final-sql.log`. Девять новых migrations 1.2.0
  применены только локально. Новые qualified event_update variables проверены
  именно этим clean reset, не только ручным обновлением функции.
- 27 независимых races passed: 7 base + 5 social + 6 events + 3 clubs + 6 push,
  `stack-final-races.log`; включает конфликт двух переносов события/состав/notify.
- Actual local security advisors: 0 issues, `stack-final-security.log`. Последний
  scoped read-only `candidate_security_review` новых avatar/moderation/event-edit
  SQL/server boundaries также без конкретных findings; не hosted integration. Последний
  lint 72 warning + 15 warning-extra / errors 0, `stack-final-lint.log`; не warning-free audit.
- Финальный actual Edge/Auth/Storage E2E и Node E2E: каждый 23 passed + 5 skipped
  суммой независимых файлов, exit 0. `stack-final-edge-isolated-e2e.log`,
  `stack-final-node-isolated-e2e-fixed.log`. Cleanup новых runs прошёл.
  Первоначальные combined Edge и Node runs 23 cases passed, но cleanup 429 от shared
  IP budgets оставил whole suite failed. Local-only runner выполняет файлы
  последовательно и сбрасывает только shared IP password/login/signup/recover/
  refresh между suites, сохраняя user/email budgets и реальные in-suite assertions.
  Guards: local API/DB 54322/postgres; production limits не менялись.
  CI test:e2e использует `server/scripts/test-e2e.mjs`.
- Прежний Release iOS26 unit 158 / 17 suites passed после event/Home/edit changes,
  до последних Appearance/Home AX layout changes,
  `unit-release-events-final-26.xcresult/log` (TEST SUCCEEDED).
- Последние Home/Appearance accessibility targeted tests passed на26 и27, но
  полная текущая matrix/physical accessibility acceptance не выполнена. Исправлены реальный Home AX overflow
  x−52/507→0/402, слабый контраст трёх Home подписей (теперь 6.18–9.52) и
  наследование foreground styles Appearance через явный Color.primary.
  Appearance имеет native scroll content margin 24 pt. Последний завершённый27 bundle до финальной title правки
  `ui-appearance-icons-final-27` TEST SUCCEEDED 2/2: реальные icons 115.366s,
  Home/Appearance audit 121.751s. AX26 `ui-appearance-scroll-local-26` failed 105.659s
  только по четырём textClipped reports pending-result title (frame 20.3pt, glyph
  crop полный); icon/footercontrast исправлен. Новый waiver не добавлен.
  Финальная минимальная Home title layout correction (flexible width/layoutPriority
  вместо unused Spacer) исправила26 reports: `ui-home-flexible-title-26`
  TEST SUCCEEDED 1/1, 99.440s, 0 failures. Latest27 title regression также passed
  131.807s, TEST SUCCEEDED (`ui-home-flexible-title-27`). Все прежние reports
  закрыты latest targeted audits без clipping/unknown waiver; matrix/physical pending.
  Handler в Home и Appearance исключает и логирует только contrast scroll
  StaticText/Button за native bar viewport (ScrollView/CollectionView); fully visible
  text и остальные категории strict. DynamicType/textClipped отдельно от contrast,
  перед которым viewport проверяется; footer минимум 16pt выше tabbar.
- Coach schedule/enrollment и score 409 canonical correction затем passed,
  `ui-event-flows-27.xcresult`; этот bundle всё ещё failed из-за lazy Home Cancel
  selector. После scrollIntoView Home canonical next-training test passed,
  `ui-event-edit-final-27.xcresult`: первоначально event-edit conflict failed по
  неполной team_id fixture. Valid fixture run дошёл до title assertion с оставшимся
  суффиксом; Select All attempt не нашёл menu. После валидного ввода
  `ui-event-edit-canonical-draft-27.xcresult/log` passed 94.755s, TEST SUCCEEDED:
  version 1→2, current location и title == visible corrected draft, no POST/DELETE.
  Полный UI26 `ui-full-events-final-26` завершился: 30 tests, 28 passed / 2 failed
  (Home audit и MatchCreate), `ui-full-events-final-26-summary.json`; whole suite failed.
  Исправлен тестовый scroll helper: Form/List представлены также CollectionView/Table.
  Последующий isolated MatchCreate прошёл на iOS26 за 86.469s и на iOS27 за 116.614s:
  `ui-home-match-corrections-current-26` (whole bundle failed по Home) и
  `ui-match-scroll-debug-27` (TEST SUCCEEDED). Это не полный повтор UI matrix.
- Новый full UI26 `ui-release-candidate-full-26` завершился: 30 total,
  29 passed / 1 failed / 0 skipped, TEST FAILED;
  `ui-release-candidate-full-26-summary.json`. Единственный отказ:
  `CommunityReleaseUITests.testRejectedPublicationCanBeCorrectedAndUncertainRetryKeepsIdentity`,
  line 36 raw body 91 bytes !=91bytes при повторе; idempotency-key assertion прошёл.
  Причина — недетерминированный порядок JSON keys при новом encoding одинакового
  payload. Exact-wire unit regression сначала воспроизвёл дефект: APIClient 11 tests /
  1failed, unique captured bodies > 1 (`unit-rebuilt-submission-red-27`, line 221).
  JSONCoding.encoder.outputFormatting=[.sortedKeys] применён без waiver.
  Первый wrong-method selector запустил 0 tests, это UNKNOWN, не verification PASS.
  Первый optimized unit27 `unit-stable-submission-final-27` BUILD FAILED до tests:
  отсутствовал ENABLE_TESTABILITY, module не built with-enable-testing, 0 tests;
  это setup failure, не product failure и не PASS. Corrected optimized Release
  `unit-stable-submission-verified-27` passed 159/159, 0 fail / 0 skip, TEST SUCCEEDED.
  Optimized unit26 до preview correction также passed 159/159, 0 fail / 0 skip:
  `unit-stable-submission-verified-26-summary.json`. Publication UI27
  `ui-stable-submission-verified-27` passed 1/1, 91.632s, TEST SUCCEEDED; summary.json.
  Full UI26 до preview correction `ui-stable-submission-final-26` TEST SUCCEEDED: 30 total,
  30 passed / 0 failed / 0 skipped; summary.json, включая HomeAX/publication/MatchCreate.
  Последний full UI27 `ui-stable-submission-full-27` завершился 29/30 PASS,
  1 failed / 0 skipped: `SocialUITests.testTournamentScoreConflictReloadsVersionBeforeCorrection`,
  «Could not scroll element into view». Exactvideo показал setup/helper defect:
  Save был fullyvisible в modal без tabbar ниже искусственной границы 769.12;
  score-conflict flow ещё не начался. visibleBand теперь использует actual
  navigation/tab bars вместо hardcoded fractions, assertions не ослаблены.
  `ui-scroll-actual-bars-final-26` critical 2 tests (MatchCreate и score409 actual version)
  passed 2/2. Последующий retry full27 `ui-final-current-full-27` был TEST INTERRUPTED,
  exit 75 после появления новых требований; это не PASS. Его218file manifest
  относится к прежним исходникам.
  Обе runtime27 clones фактически AX-extra-large (evidence
  `ui-stable-submission-full-27-content-size.json`). Full26 30/30 и units 159 каждой OS
  проверяют binary до новой Appearance preview правки, не всю current matrix.
- Visual QA обнаружил реальное наложение 64pt icon previews на подписи, несмотря
  на прежний AXpass. Preview в AppearanceSettingsView локально уменьшен 64→24pt;
  `ui-icon-native-size-final-{26,27}` каждый 2/2 PASS (HomeAX + realicons). Visual26
  overlapresolved; visual review обеOS затем подтвердил отсутствие наложения.
  Прежний full26/units159 до layout fix
  сохраняются историческими. Unit26Release159 `unit-icon-native-size-final-26`
  завершён exit 0 до следующих требований; позднее unit26 прошёл 163 / 163 до ChatView fix.
- Прежний UI26 full 23/24; ошибочный AX selector admin 409 затем исправлен и
  targeted test passed. UI26 dark/AX-extra-large10/10 passed. Это прежние
  ограниченные прогоны, не полная текущая matrix.
- Настоящие UIKit icons 27: Лайм→Графит→Мяч→Лайм, OS state/alerts/Home Screen и
  cold relaunch passed, `ui-icons-final-27.xcresult`, `icons-home-screens/`.
  Подписанный physical production iPhone ещё нужен.
- Build gates 4 API URL + 5 push/profile passed. Прежний generated Edge check
  После shared gateway-url helper extraction (с сохранением reexport) config
  Deno check exit 0 + 6 runtime passed: `netlify-isolation-deno-config-check.log`,
  `netlify-isolation-deno-config-test.log`. Начальная попытка неверного config
  path failed и сохранена, не является актуальным успешным результатом.

Исторический unsigned arm64 archive после icon preview 24pt correction succeeded:
`archive-icon-native-size-local.log`; IPA
`ios/build/verification/PadelID-1.2.0-icon-native-size-local-unsigned.ipa`, 3727144 bytes,
SHA256 **bc023bab52911e53d485d31d3465f681d33d1cb0c70cdd037c9371bd12a656e6**.
`ipa-icon-native-size-local-source.json`: 127 hashes совпадали с исходниками до трёх новых дополнений,
signed=false, published=false. Static verify IPA OK 1.2.0(3):
`ipa-icon-native-size-local-verification.log`. Shipping ENABLE_TESTABILITY=NO,
push NO / fallback empty. Прежние IPA 06bf/818d/220ed/0ff448 исторические и устарели.
Read-only signing/device check: valid signing identities 0, team empty; paired
physical device доступен, но actual signed installation не подтверждён.
До preview fix unit26/27 каждый 159 PASS, full26 30/30 passed. Исторический unit26 Release `unit-icon-native-size-final-26` завершён;
full27 `ui-final-current-full-27` позднее прерван (exit 75).
Signed physical production/network/APNs acceptance не выполнены.

## Локальная среда и продолжение

Colima existing profile padel-id, `DOCKER_HOST=unix:///Users/emilsvifullin/.colima/padel-id/docker.sock`
задавать только per-command. Actual Supabase API 54321/PG 54322 (PG17.6/Auth/Storage),
Node API8787. Перед local reset fixture backup сохранён 0600 в
`/tmp/padel-local-stack-before-reset.dump`; hosted reset не выполнялся.
Локальные `/tmp/padel-local-stack.env`, `/tmp/padel-local-node-env.json` 0600,
значения не печатать. После SQL/races восстановить прежний local secret для E2E;
не путать это с изменением hosted конфигурации. Auth E2E чистит свои аккаунты.

Xcode с `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; UI Debug
(test hooks), unit Release, shipping hooks запрещены. Node 22
`/opt/homebrew/opt/node@22/bin/node`, Deno `/tmp/padel-deno-runtime/deno`2.9.7,
SupabaseCLI2.116.0. 26sim C36E0EFC-A2A7-480B-809F-4ECF72FA9912;
27sim 1611E4ED-EB3B-457D-B634-B65FE950B7A6.

Три отдельных отказа исторического full UI27 (29 / 32) закрыты локальными
focused проверками; старый bundle остаётся failed. Players repeat `ui-players-awake-27` прошёл с предотвращением сна Mac:
1 / 1 PASS, 167.885 s, exit 0. Chat poll/send regression воспроизведён RED;
loadError/sendError fix прошёл GREEN 14 / 14. Focused icons/chat26 / 27 каждый
3 / 3 PASS, 0 fail / skip, exit 0. Visual review27 подтверждён: три настоящие иконки и читаемые настройки AX-extra-large.
Current event409 UI27 с final native button query прошёл: 1 / 1 PASS, 128.801 s, exit 0;
прежний scroll target 158.180 s исторический.
Full26 завершён: 31 passed / 1 failed. Причина подтверждена как test-only wrapper
query defect; corrected focused26 прошёл 1 / 1 за 108.138 s. Это не новый full 32 / 32,
полная текущая matrix ещё не принята.
Последние Release27 units 168 / 168 PASS; Release26 и targeted UI27 pending.
Units164 обеих OS исторические.
Backend 107, SQL 83 и реальные Node/Edge E2E 23/5 прошли. Прежний shipping archive
и IPA d56bc прошли static verification до concurrency fix; 127 app hashes, только ChatView изменён
относительно 69667. Units163 и IPA69667 исторические. Полные UI bundles
31 / 32 и 29 / 32 остаются историческими failed, новый полный UI не принят.
Исторические failed/interrupted bundles и старые IPA сохраняются. CI/UI/physical
проверки требуют фактических результатов. Production поставка разрешена новым
поручением; backup выполнен, завершить новые checks → integrated CI →
11 migrations/API → новый проверенный Release. Старый Release draft5f3 заменить.
Signing/install и физическая приёмка не выполнены; это явно сообщить при публикации.
Выпуск с уведомлениями внутри приложения и без APNs явно согласован. МегаФон без VPN
отложен и не должен останавливать разрешённую поставку.
Полный журнал: `docs/verification/1.2.0-acceptance.md`.

---

# Историческая передача Padel ID 1.1.0

Сверено 10 октября 2026. Production release пока не опубликована.

## Рабочая копия и сохранность

- Текущая полная рабочая копия: `/Users/emilsvifullin/.codex/.chatgpt-projects/g-p-6ac94fa93aac81919f402b6b15241137/padel-id`.
- Ветка: `codex/padel-id-evolution-2026-10-09`; коммит реализации: `ad4e49a8141e58b50abebea62cfc861c5def8355`, tree: `feea43e07da0fe1421c53057ceb466c0bf3fc697`. Последующий коммит содержит только итоговую документацию передачи. Точный HEAD: `git rev-parse HEAD`.
- База ветки и последний проверенный GitHub main: `50d3ca6e4f6e7590f01c27d8172e7964da8c91c7` (1.0.0).
- Полная исходная копия `/Users/emilsvifullin/Developer/Padel ID` осталась на `claude/affectionate-volta-vpolwa`; пользовательский untracked `.DS_Store` сохранён. На старте tracked изменений не было. Выполнен безопасный fetch; shallow/partial clone отсутствуют.
- Первоначальный отдельный worktree: `/Users/emilsvifullin/Developer/padel-id-codex`. Все изменения и тесты до смены режима среды выполнены там; он сохранён. После смены прав создан независимый clone в разрешённой папке выше. 284 tracked/new исходных файла перенесены, SHA256 каждого сравнен. Ignored зависимости и generated Xcode project не переносились.
- `git fsck` исходной копии отмечал существующий `.git/refs/.DS_Store` как invalid ref; основной tree/объекты доступны, служебный файл не удалялся.
- Синхронизированные `sources/` ChatGPT-проекта пусты и не изменялись.
- Последнее разрешение пользователя: «Главное, даю на все разрешения, от тебя я должен получить только доработанную production release версию». Необходимые commit/push/PR/merge/production migrations/deployment/Release разрешены. Администратора назначать не нужно; эта операция не выполнялась.

## Выполненная реализация

1. Пять постоянных вкладок, ракетка для матчей, ближайшая принятая будущая игра на Главной. Прежний Home перенесён в AnalysisView, Account — в Профиль со всеми настройками/безопасностью/coach/admin/logout/delete. Основные файлы: App/MainTabView, AppModel, Routes; Features/Home, Settings/AccountView.
2. Взаимная дружба, входящие/исходящие заявки, принятие/отклонение/отмена/удаление, профиль другого игрока и выбор друзей рядом с recent/global search. Основные файлы: Features/Players/FriendsView, PlayerProfileView, PlayersView; MatchEditor/EditorPlayerPicker; Core/Models/SocialModels.
3. Будущая игра отдельна от сыгранного результата: публикация, набор четырёх, admission/заявка организатору, review, leave/cancel, ввод счёта с точным принятым составом и существующей outbox. Основные файлы: Features/Matches/Upcoming*, MatchEditorModel/View; server/src/api.ts/errors.ts.
4. Две новые миграции: `20261009204129_social_and_upcoming_matches.sql` и `20261009204131_complete_result_streak.sql`. Применённые миграции не редактировались. Canonical friendship pair, locks/capacity, RLS/no direct table grants, session/organizer rights, idempotency, exact linked result validation, четыре confirmations и прежняя рейтинговая математика сохранены.
5. Воспроизведённые гонки удаления аккаунта с join/result закрыты: sorted profile FOR SHARE locks, повторное закрытие только linked pending/disputed результатов после ожидания очистки. Confirmed история сохранена. Legacy PUT ограничивает участников, тип, клуб и backdating; optional scheduled_match_id/starts_at возвращаются сразу при POST и GET. Повтор результата сверяет original canonical payload без повторной проверки изменившихся временных окон.
6. DNA Diagram/Indicators на прежней шкале 0–7, реальные последние десять подтверждённых результатов и непрерывная серия по всей истории. Карточки показывают уровень/reliability/preferred side. Основные файлы: DNADetailView, RecentFormSummary, StatsDetailView, Components, Models.
7. Выбор фото нажатием на круг, сохранены remove/loading/errors/offline/a11y; destructive binary confirmations — native alert. Убрана дополнительная анимация системного type picker. RatingDetail готовит snapshot вне MainActor, переиспользует периоды, vectorized Chart сохраняет все точки; cancellation/stale responses защищены. Reduce Motion сохранён.
8. Отзыв доступа к hidden profile очищает profile/DNA/четыре rating periods/match history caches и отвергает поздние ответы; transient503 сохраняет cache. Основные файлы: Resource, ResponseCache, RatingDetailView, MatchesListPager.
9. Исправлены реальные UI отказы: постоянный navigationBarDrawer search после переноса каталога; общий value Route.upcomingGames вместо mixed direct/value push списка игр. Повторный строгий тест linked-result после этой правки прошёл. Неопределённый ответ публикации сохраняет параметры и key для retry; форма блокируется. Test-only upcoming fixtures привязаны к текущей дате.
10. Версия 1.1.0, build2. Добавлены DB-export fixtures, unit/UI/concurrency/E2E regressions. Обновлены README/backend/ios-architecture; подготовлены design-research, release notes, release-1.1.0 и PR_DESCRIPTION.md. Две темы и Dynamic Type учитываются в UI; четыре реальные CI конфигурации ещё предстоит проверить.

Полный список: `git show --stat ad4e49a`; проверки не удалялись и не ослаблялись. Новых runtime зависимостей в приложении нет.

## Решения и допущения

- Автодопуск: effective reliability ≥70%, ranked_matches ≥5 и mu внутри включительного диапазона 0–7, выбранного организатором. При меньшей надёжности/числе игр — заявка; надёжный уровень вне диапазона получает отказ. Это выбранные в реализации числа, а не согласованный ранее порог; пять/десять игр не гарантируют надёжность. Формула рейтинга не менялась.
- Любой принятый участник после начала при полном составе может внести результат. Можно переставлять реальные принятые пары/стороны, нельзя подменить состав/тип/клуб/начало. Принятие участия не подтверждает счёт.
- Social/scheduling mutations требуют сети; чтение cache-first. Отправка счёта использует прежнюю надёжную очередь.
- Accepted friends и admitted scheduled peers расширяют existing common profile visibility. Hidden requester добровольно доступен получателю своей заявки; скрытый получатель исходящей заявки не раскрывается. Email и личные настройки не входят в player cards.
- Источники Apple/Emil Kowalski/Lunda/Telegram/Sofascore/FotMob/Playtomic и границы наблюдений записаны в docs/design-research.md. Установленные приложения конкурентов и недоступный JS-каталог Lunda не объявлялись исследованными. Веб-зависимости не перенесены.

## Фактические проверки

Логи/xcresult: `/tmp/padel-id-checks/` (локальный временный каталог). Выдержки результатов, SHA256 оригинальных логов и unit xcresult summary сохранены в `docs/verification/1.1.0-local-checks.json`; это прежние фактические результаты, а не новый прогон. Не сохранялись запросы, тела ответов и переменные окружения.

| Проверка | Результат и доказательство |
|---|---|
| PG17 migrations/schema/security/RLS/rating/domain SQL | 43 passed / 0 failed: db-tests-pg17-final.log |
| Independent connections concurrency | 7 passed: db-concurrency-pg17-final.log; last seat joins/approvals, opposing friends, publish/result retries, delete with join/result |
| Supabase lint | exit0, 0 errors / 61 warnings: db-lint-pg17-final.log; warnings о конвенциях/волатильности функций, не скрыты |
| Local advisors | 6 INFO unused indexes новой базы, 0 WARN/ERROR: db-advisors-pg17-final.log |
| Gateway Node22.23.3 typecheck/build/unit | Все passed, 46 unit: backend-final-*-node22.log |
| Full API E2E на local Supabase PG17 | 17 passed, 2 неприменимых smoke tests skipped: backend-local-e2e-final.log |
| Local smoke mode | 2 passed, 13 неприменимых full tests skipped: backend-local-smoke-final.log; temporary auth accounts удалены |
| Защита от full E2E на hosted API | Отказ до тестов, exit1 на example.invalid: backend-remote-full-guard.log |
| iOS final Debug build-for-testing | Passed: ios-build-routes.log; Xcode27.0/SDK27, deployment target26 |
| iOS unit | 106 passed, 0 failed/skipped (137 исполнений с параметризованными fixtures): unit-verified.xcresult, ios-unit-verified.log |
| Local UI regressions | Social4/4 passed: ui-routes.xcresult/ios-ui-routes.log. Home2/Players1 passed в предыдущем целевом прогоне: ui-verified-booted.xcresult. После последних текстовых/route правок full matrix требуется на GitHub |
| Diff/side files/credential patterns | git diff --check passed; 113 изменённых/new files проверены перед commit, credential-pattern matches нет; старые migration files не изменены |
| Production preflight | До изменений health/deep старого50d3ca6 databaseok; 12 старых migrations. Dry-run exit0 показал только два новых файла, seeds/roles пусты: production-migrations-dry-run.log. Read-only DB подтвердил session/gateway guards и три предусловия guarded transformations |
| Production hosted advisors baseline | WARN о намеренно вызываемых SECURITY DEFINER RPC (anon bff_rate_limit и33 authenticated) и existing disabled leaked-password protection. Это не чистый hosted audit; все RPC имеют explicit gateway/session/domain guards |
| Local Release archive после смены sandbox | НЕ прошёл, exit65: ios-archive-candidate.log. sandbox_apply Operation not permitted блокирует Swift plugin server/Observation/SwiftUI macros; также simulator IPC/log access denied. IPA не создана и не проверена |
| GitHub Actions новой версии | НЕ запускались: запись GitHub блокирована средой |
| Физический iPhone/FPS/Instruments/SideStore/iLoader | НЕ проверены: устройства нет в доступном состоянии |
| Wi-Fi без/с VPN, LTE без/с VPN, Wi-Fi↔LTE/outage/retry | НЕ проверены на реальном iPhone/сетях; checklist docs/release-1.1.0.md |

История диагностик сохранена: первый unit98 имел ошибку тестового сравнения unordered JSON bytes — исправлено canonical semantic comparison + exact persisted retry bytes,106 passed. Первый full UI10/11 имел search regression — исправлена и повторно passed. Целевой UI6/7 выявил mixed navigation detail loading — Route.upcomingGames исправление и Social4/4 passed. Один UI старт failed simulator Busy — после explicit boot повтор выполнен. Первый SQL после E2E имел5 failures из-за непустого disposable DB; правильный reset и CI order дали43/43. Эти неуспешные попытки не считаются зелёными.

## Текущая блокировка поставки

Управляемая среда разрешает запись только в ChatGPT-project/tmp, CLI network ограничена. Исходные Developer-копии теперь доступны только для чтения. GitHub connector отклонил создание remote tree до исполнения: **«MCP tool call requires approval, but approval policy is never»**. Ваше разрешение на поставку есть, но текущая policy не позволяет соответствующую операцию. CLI тоже не соединяется с api.github.com. Не обходить этот отказ через другие инструменты, UI или изменение sandbox flags.

Remote branch/PR не созданы. Миграции не применены в production, main не слит, Vercel production остался на1.0.0, новый Release не запущен. IPA отсутствует. Локальный код и документация готовы, production-ready приёмка НЕ завершена.

При последующем продолжении повторный read-only GitHub GET подтвердил main50d3ca6 и latest releasev1.0.0. Выбранные публичные поля ответа сохранены в `docs/verification/1.1.0-remote-state.json`. Проверка пакета поставки не обнаружила противоречий в четырёх конфигурациях и распределении unit/UI, порядке migrations/smoke/Release, версии1.1.0/build2 и verify-ipa; проверенные shell scripts прошли `bash -n`. Новые CI/device результаты не получены. Проверка последнего Social xcresult summary дополнительно отказала при записи внутреннего TestReport; успешный результат4/4 подтверждается исходным ios-ui-routes.log. Исходники приложения на этом этапе не менялись.

После сохранения доказательств повторно сверены SHA256 и каждая выдержка с10 оригинальными логами; JSON разобран успешно. `git diff --check`, синтаксис трёх shell scripts и поиск credential patterns в файлах передачи прошли. Diff migrations содержит только два добавленных файла. Последний коммит передачи содержит HANDOFF.md, PR_DESCRIPTION.md и три файла docs/verification; новые изменения приложения отсутствуют.

## Конкретный следующий шаг

Продолжить в среде с доступом к GitHub/production и разрешённой записью. Продуктовых вопросов не требуется. Сначала проверить текущий main, push отдельной ветки и открыть PR по PR_DESCRIPTION.md; дождаться backend и всех четырёх iOS jobs, скачать/просмотреть screenshots. При failure исправлять причину, не checks.

```sh
cd /Users/emilsvifullin/.codex/.chatgpt-projects/g-p-6ac94fa93aac81919f402b6b15241137/padel-id
git status --short --branch
git fetch origin main
git log --oneline --left-right origin/main...HEAD
# Если main изменился, интегрировать его без потери работы и повторить затронутые проверки.
git push -u origin codex/padel-id-evolution-2026-10-09
gh pr create --base main --head codex/padel-id-evolution-2026-10-09 --title 'Padel ID 1.1: друзья, открытые игры и понятный анализ' --body-file PR_DESCRIPTION.md
# В Codex attach_artifact для URL созданного PR.
```

После зелёного CI и screenshots review — docs/release-1.1.0.md: supported CLI dry-run, только две migrations с сохранением file versions/skip-vault → merge проверенного PR → Vercel exact commit health/deep и Production smoke → Release workflow наmain publish=true → скачать IPA+checksum и verify-ipa → физическая приёмка. Supabase MCP apply_migration назначает собственные versions и не заменяет этот подготовленный CLI путь; не импровизировать repair migration history.

Локальное окружение прежних проверок: isolated Colima padel-id (`DOCKER_HOST=unix:///Users/emilsvifullin/.colima/padel-id/docker.sock`), Supabase54321/54322 PG17, gateway8787. SQL/concurrency требуют pristine disposable DB ДО fixtures/E2E/secret; production не сбрасывать. Xcode через DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer, XcodeGen2.45.4 в /tmp/padel-id-checks/xcodegen. Exact workflows остаются источником обязательных команд. Secrets в handoff/артефактах отсутствуют.
