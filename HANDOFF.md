# Padel ID 1.2.0 — состояние работы

Обновлено 13.10.2026. Ветка `codex/padel-id-1.2.0-production`, PR 3. Релиз не
опубликован, production не менялся. Журналы прежних проверок —
`docs/verification/1.2.0-acceptance.md`; этот файл описывает только текущее
состояние и удаляется перед публикацией.

## Что сделано

- **Серверная часть 1.2.0** (сообщество, закрытые игры, тренировки, турниры,
  клубы, приватные аватары): 12 новых миграций в `supabase/migrations`, шлюз в
  `server/src`. Backend CI зелёный.
- **Сеть.** Без изменений относительно 1.1.0: сборка ходит на единственный
  адрес `padel-id-gamma.vercel.app`. Работа без VPN отложена владельцем; замеры
  и заготовки — `docs/verification/network-audit-1.2.0.md`, ветка
  `network/ingress-relay`.
- **Редизайн.** Новая дизайн-система (`ios/PadelID/DesignSystem/Theme.swift`,
  `Brand.swift`), правила — раздел «Visual language» в
  `docs/ios-architecture.md`. Переделаны вход, Главная, Матчи, Клубы,
  Сообщество, чаты, публикации, Профиль, игры, события; остальные экраны
  переведены на новые шрифты, кнопки и состояния выбора.
- **Функции.** Подбор игроков в Сообществе, достижения в статистике, открытый
  чат обновляется каждые 4 секунды.

## Что осталось

1. **Зелёный CI** на четырёх конфигурациях iOS после редизайна.
2. **Production**, по `docs/release-1.2.0.md`: проверить резервную копию →
   применить 12 миграций через CLI с сохранением версий файлов → слить PR
   (Vercel выкатывает API) → smoke → собрать IPA и опубликовать GitHub Release.
   Миграции и публикация — только после явного «да» владельца в момент
   выполнения. Клиент 1.1.0 продолжает работать, включая аватары: шлюз читает
   их для него своим секретом.
3. **Приёмка на iPhone** по `docs/verification/iphone-1.2.0.md` и итоговый
   отчёт владельцу.

## Что не входит в 1.2.0

- Работа без VPN: отложена владельцем до следующего этапа.
- Push через APNs: установка идёт через SideStore с бесплатным Apple ID, а для
  push нужен платный аккаунт разработчика. Код есть, флаг сборки выключен.
- Фотографии в публикациях.
- Собственное бронирование кортов: только проверенная ссылка на сайт клуба.

## Ограничения владельца

- Не трогать проект Shift Register, его DNS, конфигурацию и данные. Имя
  `api-padel.shiftregister.ru` уже привязано к проекту Padel ID на Vercel.
- Не менять `PADELID_GATEWAY_SECRET`.
- Платный сервер не покупать без отдельного согласия.

## Как посмотреть и проверить

```sh
cd ios && xcodegen generate
# Сборка для симулятора; с такой подписью связка ключей сохраняет сессию.
xcodebuild build -project PadelID.xcodeproj -scheme PadelID -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
# Полный набор тестов, как в CI: симулятор создаёт scripts/ios/simulator.sh.
xcodebuild test -project PadelID.xcodeproj -scheme PadelID -configuration Debug \
  -destination "platform=iOS Simulator,id=$(../scripts/ios/simulator.sh 'iPhone 17 Pro' light large)" \
  -parallel-testing-enabled NO
```

UI-тесты поднимают заглушку API внутри тестового процесса
(`ios/PadelIDUITests/StubServer.swift`); запущенное вручную приложение можно
направить на любой локальный сервер переменной `PADELID_UITEST_API_BASE_URL`.

Прямой замер сети с Mac в обход VPN:
`curl --interface en0 --resolve <host>:443:<ip> https://<host>/v1/health`.
