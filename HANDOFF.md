# Передача Padel ID 1.1.0

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
