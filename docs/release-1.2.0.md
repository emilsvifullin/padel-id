# Padel ID 1.2.0 — процедура поставки кандидата

Статус: не опубликован, 12.10.2026. Read-only GitHub release history подтверждает
v1.0.0 (09.10) и v1.1.0 (10.10), поэтому 1.2.0 является следующим production
номером. Доказательство: ignored `ios/build/verification/release-history-current.json`.
Повторить историю перед настоящей публикацией, если она отложена.

Последнее явное поручение пользователя: завершить production-релиз 1.2.0 сейчас.
Разрешены необходимые Git/release/deployment операции и production migrations/API
после резервирования и CI. Доступность через МегаФон без VPN пользователь вынес
за текущий scope; это отдельная незавершённая задача, а не gate этой публикации.
Production операции ещё не выполнены. PADELID_GATEWAY_SECRET не менять;
Shift Register, его конфигурацию и данные не трогать. Владелец явно согласовал выпуск 1.2.0 с уведомлениями внутри приложения.
APNs отложен на отдельный этап; shipping push NO — согласованное ограничение
этого релиза, а не ожидающее решение или gate публикации.

## Подготовка разрешённой поставки

1. Сверить exact commit и обязательные backend/iOS CI checks. Локальные результаты
   и исторические failed bundles сохранены в журнале приёмки.
2. Выполнить backup/dry-run и десять migrations, затем deploy API и production-safe
   smoke. Сетевую проблему МегаФон без VPN оставить отдельной задачей.
3. Выпустить с уведомлениями внутри приложения; APNs явно отложен владельцем.
   Shipping push NO сохранить, Apple provisioning/worker активировать позже отдельно.
4. Проверить старый клиент/приватные аватары, собрать release artifact/checksum,
   опубликовать фактические release notes с честными ограничениями физической приёмки.

## Сохранность и миграции

Сначала read-only сверить hosted schema/migration history и exact API revision,
сделать резервирование production доступным утверждённым способом. Проверить
supported CLI help/dry-run перед применением и сверить, что предлагаются ровно
эти десять новых файлов, без seeds/roles/редактирования прежних applied migrations:

- `20261010160145_social_ecosystem.sql`
- `20261010160723_sports_events.sql`
- `20261010161418_private_games_and_waitlists.sql`
- `20261011010023_clubs_catalog_booking_foundation.sql`
- `20261011020756_apns_push_foundation.sql`
- `20261011162115_coach_discovery_and_schedule.sql`
- `20261011162125_private_avatar_storage.sql`
- `20261011162259_moderation_content_review.sql`
- `20261011163321_event_schedule_management.sql`
- `20261012073216_club_news_feed.sql`

Локальная цепочка теперь содержит 24 миграции. Новости клуба используют прежние
posts с club_id фильтром, атрибуцией и live admin guard. `EventEditDraft` сохраняет
локальные правки при 409 и требует явного keepDraft/useLatest; профиль открывает
Route.myEvents. Current backend: 107 / 107, SQL: 83 / 83 в rollback/savepoint
изоляции. Реальные Node/Edge E2E: каждый 23 passed / 5 skipped. Данные 78 таблиц
и secret fingerprint сохранены. Первоначальный SQL77/6 — historical isolation
failure; доказательства: `club-news-backend-*` и журнал приёмки.

Исторические Release units26/27 до ChatView fix `unit-draft-club-news-current-{26,27}`: каждый
163 / 163 PASS. Targeted UI27: 4 passed / 1 failed из 5. Account, две news и
score409 прошли; event-edit остановился до 409 на первом title input. Видео
подтвердило задержку наблюдения корректно введённого текста. Исправлен только
helper: waitUntil до 15 секунд после typeText, прежний строгий assert без повторного
ввода. `ui-event-draft-observed-27` затем failed 1 / 1 на втором title edit после
keepDraft: title оказался выше viewport lazy Form. AX evidence подтвердил, что
черновик не потерян. Helper теперь scrollIntoView(title, searchBelow:false) перед
require; wait 15s и точные assertions сохранены. Новый `ui-event-draft-scroll-27`
TEST SUCCEEDED, exit 0: 1 / 1 PASS, 0 failed / 0 skipped, 158.180 s. Проверены
видимый title после 409, explicit review, вторая correction и exact две PUT
операции/version/title/location assertions. Прежний `ui-event-draft-scroll-26` FAILED по wrapper query; corrected
`ui-event-draft-button-26` passed 1 / 1, 108.138 s, подробнее ниже. Current API build gates 4 / 4 PASS и push/profile
gates 5 / 5 PASS. После нового ChatView fix IPA69667 и manifest127 исторические.

Последний full UI26 `ui-draft-club-news-full-26`: 32 total,
31 passed / 1 failed / 0 skipped, exit 65. Sole failure читал isEnabled у Other
wrapper вместо Save. Видео подтвердило настоящий Save disabled и сохранённый
черновик. Test-only query исправлен на native button при прежних строгих
assertions и exact двух PUT. Focused `ui-event-draft-button-26` прошёл 1 / 1,
0 failed / 0 skipped, exit 0, 108.138 s; это не новый полный 32 / 32 PASS.
Последний native-button target27 `ui-event-draft-button-27` также прошёл 1 / 1,
0 failed / 0 skipped, exit 0, 128.801 s. Review snapshot проверен: при
AX-extra-large кнопки читаемо переносятся без наложения, Save серый и disabled.

Последний full UI27 `ui-draft-club-news-full-27`: 32 total,
29 passed / 3 failed / 0 skipped, exit 65. Отказы: disabled «Графит» во время
асинхронной смены иконки, chat element not found за 10 секунд и Players drag
synthesis timeout. Все три отдельных отказа затем покрыты focused PASS. В ChatModel найден реальный дефект: успешный poll
очищал feedback неуспешной 503 отправки. RED scoped CommunityTests
`unit-chat-send-poll-red-27` воспроизвёл единственный failure
`successfulPollPreservesUnconfirmedSendFeedbackAndRetryIdentity`, exit 65.
loadError/sendError fix прошёл GREEN Release27 14 / 14 после RED 13 / 14;
14 declarations дают 16 case invocations с privacy аргументами 401 / 403 / 404.
Текущие полные Release units26 / 27 каждый 164 / 164 PASS, 0 failed / 0 skipped,
exit 0 (`unit-chat-feedback-current-{26,27}-summary.json`). Для Players журналы
показывают сон Mac с 11:36:18 до DarkWake 11:51:36, совпавший с drag timeout;
повтор `ui-players-awake-27` с предотвращением сна прошёл без изменения
assertions: 1 / 1 PASS, exit 0, 167.885 s. Полный bundle остаётся historical
29 / 32; его counts не переписываются успешными focused retries. Icon failure был на selected
wait line 177 после alert, когда UIKit pending, а не при tap. Только test helper
теперь ждёт selected && enabled до 30 секунд до Home и обрабатывает поздний
SpringBoard alert. Продуктовый код иконок не менялся.
Focused runs `ui-chat-icons-completion-{26,27}` завершились каждый 3 / 3 PASS,
0 failed / 0 skipped, exit 0. Проверены настоящая смена иконки и три дизайна Home
Screen, возврат к Лайм по умолчанию и cold relaunch; chat 503 retry с тем же key
и подтверждённым сообщением; chat member profile context. Длительности (s):

| Runtime | Icons | Chat 503 retry | Member context |
|---|---:|---:|---:|
| iOS26 | 284.104 | 140.598 | 62.900 |
| iOS27 | 360.415 | 161.186 | 88.249 |

Доказательства: `ui-chat-icons-completion-{26,27}-summary.json`, `.xcresult/log`.
Все ранее упавшие отдельные UI cases покрыты успешными focused проверками:
event button26, icons/chat обеих OS, Players27 без сна. Исторические full26
31 / 32 и full27 29 / 32 остаются failed; свежий full 32 / 32 с текущим
ChatModel не выполнялся. Полные Release units и targeted UI подтверждены.
Visual review27 подтверждён: свежие SpringBoard screenshots показывают
Лайм → Графит → Мяч → Лайм; настройки с AX-extra-large читаемы без перекрытий.
Доказательство: `ui-chat-icons-completion-27-visual/manifest.json`.
Физическая приёмка установленной production-сборки остаётся отдельной.

Full27 собран до последних
test-only button query/snapshot additions, до нового ChatView fix;
две actual clones iOS 27.0, accessibility-extra-large подтверждены.
Прежний `ui-final-current-full-27` TEST INTERRUPTED, exit 75, не PASS.
Иконки 24 pt / Home AX26 / 27 в focused runs прошли каждый 2 / 2,
визуально обе OS без наложения, все три реальных дизайна SpringBoard подтверждены.
Полная текущая UI matrix не принята.

Исторический archive до ChatView fix `archive-draft-club-news-local.log`: ARCHIVE SUCCEEDED. IPA
`PadelID-1.2.0-draft-club-news-local-unsigned.ipa`, 3734938 bytes,
SHA256 `69667ee2ec70bd95d88c290e531ec3938c5490c8b5f5a7b69247e1c49a6c5fca`. Verify-ipa: PASS 1.2.0(3),
127 app source hashes matched до ChatView fix, signed=false / published=false.
Этот IPA исторический после ChatView fix.
Текущий shipping archive `PadelID-chat-feedback-local.xcarchive`:
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
МегаФон без VPN исключён из текущего scope по поручению пользователя.

Signing/device check не подтвердил physical installation.

По текущему разрешению применять их по порядку через установленный CLI
release workflow, с сохранением file versions. Не использовать случайный reset,
migration repair или MCP-generated versions для обхода истории.
Shared gateway secret **не заменять**: нынешний Vercel/account/SQL согласован.
Новый полный API требует существующего значения; verification relay его не знает.
Если ключ действительно недоступен для выбранной инфраструктуры, сначала обсудить
конкретную необходимость и согласованную безопасную процедуру, не вращать молча.

После миграций read-only проверить старые account/profile/rating/match/upcoming
контракты, row/table privileges и новые guarded RPC. Push config остаётся disabled,
без history backfill. Не ослаблять common live-session protection ради старого JWT.

## Порядок старого клиента и аватаров

Новый клиент запрашивает bearer-protected `/v1/avatars/...`; новый API проверяет
актуальную видимость и передаёт тот же bearer в authenticated Storage. Миграция
`20261011162125_private_avatar_storage.sql` делает bucket private и закрывает
запомненные public Storage URL отдельно от API. Signed URLs/copy/move/list
новым policy запрещены, владелец может выполнять непосредственные записи.

Read-only проверка предыдущего исходника показала: старый клиент тоже использовал
API avatar URL, но **без bearer** и с persistent returnCacheDataElseLoad. Старый
сервер загружал public Storage internally. Поэтому защищённый API ломает старый
anonymous image contract, а private bucket — remembered raw public URL. Проверить
реальный установленный binary; согласовать maintenance/update и minimum-build
gate после доступности нового API и артефакта. PADELID_MIN_CLIENT_BUILD менять
только в согласованном этапе, не возвращать public bucket ради старого клиента.

Bucket privacy запрещает будущие origin reads, но не отзывает уже скачанные
client/browser copies или прежние public CDN responses. Перед обещанием немедленного
отзыва проверить actual hosted cache policy/provider invalidation; отдельно
проверить, выдавались ли старые signed URLs, их expiry и поддерживаемую процедуру
отзыва. Новая реализация signed paths не создаёт. Локальный regression не является
подтверждением hosted cache invalidation. Подробности и официальные источники:
`verification/avatar-privacy-1.2.0.md`.

## API, CI и финальный артефакт

После разрешённых Git операций пройти backend и iOS jobs на exact commit.
Для Vercel проверить deployment/env актуальной официальной CLI документацией;
не публиковать новый API поверх отсутствующих RPC. Новый independent gateway
публиковать только с approved config/migrations. Verification relay сохранил
старую production revision; его health не доказывает наличие 1.2.0 routes.

Проверить strict TLS/no redirects, health/deep exact commit, old-user profile/
history, новые guarded reads/mutations и production-safe smoke: coach schedule/enrollment,
private avatar, конкретное reported content, own upcoming, event metadata/version/
roster/participant notifications и stale score correction. Полный E2E с
fixtures допускается только в disposable локальном stack, не на hosted данных.

Не менять URL/fallback ради незавершённого сетевого эксперимента; APNs оставить выключенным по согласованному scope. Собрать новый Release archive,
проверить IPA, version1.2.0/build3, primary/alternate metadata, arm64/privacy,
отсутствие ATS/debug hooks/test/secret/raw Supabase endpoints; сохранить SHA256.
При APNs сборке проверяется именно подписанный entitlement/profile, а не шаблон.

Публиковать GitHub Release на проверенном commit по текущему разрешению пользователя,
с IPA/checksum и фактическими release notes. Signing и physical installation пока
не подтверждены; не описывать unsigned artifact как подписанную проверенную сборку.
Физическая приёмка остаётся последующей проверкой, её отсутствие не подменяет
поручение завершить production release сейчас. Выпуск с уведомлениями внутри приложения без APNs явно согласован. Коммерческие booking integrations, которых
нет, явно описывать как внешнюю зависимость.

## Физическая приёмка

Checklist владельца: [Физическая проверка iPhone 1.2.0](verification/iphone-1.2.0.md).
Он сохраняет ограничения signing/install/APNs/network и не означает принятую поставку.

Полный checklist: `verification/1.2.0-acceptance.md`. На iPhone 17 Pro Max / iOS
27.0.1 через доступное подключение проверить новый и существующий аккаунт;
МегаФон без VPN отложен отдельно. Проверить
аватар/приватность, результат/рейтинг/outbox, chat/groups/posts/moderation,
trainings/tournaments/club activities, перенос события с сохранением состава,
Home next-event/history и переход Wi-Fi↔LTE. Проверить все темы,
реальную смену Home Screen icons, relaunch, Liquid Glass/keyboard/gestures,
Dynamic Type/VoiceOver/Reduce Motion и уведомления внутри приложения. APNs
foreground/background/terminated/logout/block/tap проверять на отдельном будущем
этапе активации. Затем повторить доступные сценарии с VPN как regression.

Локальные автоматические проверки помогают обнаружить ошибки, но не заменяют
сеть оператора, производительность физического устройства или Apple delivery.
