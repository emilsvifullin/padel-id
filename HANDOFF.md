# Padel ID — состояние работ и инструкция для продолжения

Этот файл — передача работы следующему агенту. Удалить перед финальным релизом
(шаг 9 ниже).

## Где всё лежит

- Репозиторий: `emilsvifullin/padel-id`, рабочая ветка `claude/compassionate-curie-h2syri`
  (все изменения там; `main` пока содержит только стартовый коммит).
- Supabase production: проект `xnxhlfuncxyzdfdmqlkb`.
- Vercel production: проект `padel-id` (`prj_vXX1ax3AjlMfW83jHp3rwWUsoI1X`, team
  `team_d3mgGNpjDXKP40wD4Bnh07Ad`), домен `https://padel-id-gamma.vercel.app`,
  root `server/`, продакшен собирается из `main`.
- Документация: `README.md`, `docs/backend.md`, `docs/ios-architecture.md`,
  `docs/release-notes/1.0.0.md`.

## Что готово и проверено

- Бэкенд: 12 миграций, 33 теста БД (`scripts/db/run-tests.sh`), 38 unit-тестов
  шлюза (`cd server && pnpm test`), e2e на локальном стеке Supabase — всё зелёное
  в CI (`.github/workflows/backend.yml`).
- iOS: собирается в CI (Xcode 26.6), 83 unit-теста проходят; UI-тесты 7 из 8 на
  всех четырёх конфигурациях. Последний оставшийся сбой — `testSignUpAndOnboarding`
  (пароль печатался в поле почты, когда SecureField не получал фокус); исправление в
  коммите `2844380` (`enterPassword` печатает только в поле с фокусом, фокус переводится
  Return из поля почты, при сбое сохраняется скриншот `password-not-accepted`) —
  **проверить результат CI**.
- Release-сборка: workflow `release.yml` собирает неподписанный `PadelID.ipa`,
  проверяет его `scripts/ios/verify-ipa.sh` — зелёный.
- Ревью выполнены и исправлены: матчи, доступность и тексты, безопасность,
  производительность, профиль/соц. функции (коммит `2e46563`). Шаг 3 ниже — **сделан**.
- В production Supabase применены миграции `20261008160000_match_history_cursor` и
  `20261008210000_security_and_search`; Edge Function `account` (версия 2, с
  `padelid_origin`) задеплоена; `Production smoke` после этого зелёный
  (регистрация и удаление временного аккаунта работают). Шаги 4 и 5 ниже — **сделаны**.

## Что осталось (по порядку)

1. **iOS CI зелёный.** Дождаться/проверить workflow `iOS` для последнего коммита.
   Скриншоты и краткие сводки тестов публикуются как prerelease `ui-screenshots`:
   `curl -L -o s.zip https://github.com/emilsvifullin/padel-id/releases/download/ui-screenshots/screenshots.zip`
   (внутри `<конфигурация>-summary.txt` с упавшими тестами). Чинить до 8/8 на всех
   конфигурациях. Никогда не отключать и не пропускать тесты.
2. **Фикстуры собственного профиля для UI-стаба (желательно).** Стаб уже умеет
   отдавать `player_profile_me.json` / `player_matches_me.json` для id
   `03eed36a-a8a4-4767-9dd6-b1f89bf7267b`. Добавить их экспорт в
   `scripts/fixtures/export.sh` (`player_profile(me)`, `player_matches(me, null, 30, null)`),
   прогнать скрипт (локальный PostgreSQL, см. `scripts/fixtures/README.md`),
   положить JSON в `ios/PadelIDUITests/Fixtures/` и `ios/PadelIDTests/Fixtures/`.
3. **Ревью «профиль/соц. функции»:** iOS (`Features/{Auth,Onboarding,Shared,Home,Rating,DNA,Players,Settings,Coach,Admin}`,
   `App`, `Core`) против SQL и шлюза: пути/тела запросов, декодирование, ошибки,
   очистка состояния при выходе/удалении, правдивость чисел. Исправить найденное.
4. **Production: Edge Function `account`** — задеплоить текущую версию
   `supabase/functions/account/index.ts` (verify_jwt = false). Она ставит
   `app_metadata.padelid_origin = 'account-service'`. **Обязательно до шага 5**,
   иначе регистрация сломается.
5. **Production: миграция `20261008210000_security_and_search`** (sha256
   `d508fc6943e3b325a17e1bb42d15d5a920e2466c952311f196d4e2e82c1dd5ca`).
   MCP `apply_migration`/`execute_sql` таймаутит на больших SQL. Рабочий способ:
   1) `select net.http_get('https://raw.githubusercontent.com/emilsvifullin/padel-id/<полный SHA коммита>/supabase/migrations/20261008210000_security_and_search.sql');`
   2) отдельным запросом `do $$ … $$` прочитать `net._http_response` по id,
      проверить статус 200 и sha256 (`extensions.digest(convert_to(content,'UTF8'),'sha256')`),
      `execute` содержимое и вставить строку в `supabase_migrations.schema_migrations`
      (version `20261008210000`, name `security_and_search`).
   Затем проверить: регистрация через приложение/шлюз работает, `get_advisors`.
   В панели Supabase (Auth → Sign In / Providers) выключить «Allow new users to sign up»
   (триггер в БД всё равно блокирует прямые регистрации).
6. **PR в `main`** из рабочей ветки, дождаться зелёных `backend`, `iOS`, `Release`,
   слить merge-коммитом. Vercel сам задеплоит production из `main`; проверить
   `GET https://padel-id-gamma.vercel.app/v1/health` — поле `commit` = SHA слияния,
   и workflow `Production smoke` на `main` — зелёный.
7. **Релиз:** запустить workflow `Release` вручную на `main` с `publish = true`.
   Он соберёт и проверит `PadelID.ipa`, удалит prerelease `ui-screenshots` и
   создаст GitHub Release `v1.0.0` с `PadelID.ipa` и `PadelID.ipa.sha256`.
8. Проверить, что в релизе есть `PadelID.ipa`, а артефакт `PadelID.ipa` есть в запуске.
9. Удалить этот `HANDOFF.md` (отдельным PR/коммитом в `main` до шага 7 или после —
   тогда без нового релиза).

## Правила

- Секреты (service role, gateway secret) никогда не попадают в репозиторий, логи,
  приложение или IPA. Service role — только в окружении Edge Function.
- Не переписывать уже применённые миграции — только новые файлы.
- Коммиты — в рабочую ветку; в `main` — только через PR.
- Весь интерфейс на русском; никаких заглушек, моков в release, TODO.
