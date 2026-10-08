// Error contract of the Padel ID API: every failure is
//   { "error": { "code": "<machine code>", "message": "<Russian text>" } }
// with an HTTP status derived from the code. The iOS client keys its UX off the
// code; the message is a human-readable fallback.

export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly detail: string | undefined;

  constructor(status: number, code: string, detail?: string) {
    super(code);
    this.status = status;
    this.code = code;
    this.detail = detail;
  }
}

interface ErrorSpec {
  status: number;
  message: string;
}

const SPECS: Record<string, ErrorSpec> = {
  // Generic
  invalid_request: { status: 400, message: "Некорректный запрос." },
  not_found: { status: 404, message: "Не найдено." },
  forbidden: { status: 403, message: "Недостаточно прав для этого действия." },
  rate_limited: { status: 429, message: "Слишком много попыток. Попробуйте немного позже." },
  payload_too_large: { status: 413, message: "Слишком большой запрос." },
  service_unavailable: { status: 503, message: "Сервис временно недоступен. Попробуйте ещё раз." },
  internal: { status: 500, message: "Что-то пошло не так. Попробуйте ещё раз." },
  client_outdated: { status: 426, message: "Обновите приложение, чтобы продолжить." },
  idempotency_key_required: { status: 400, message: "Не передан ключ идемпотентности." },

  // Auth
  not_authenticated: { status: 401, message: "Войдите в аккаунт." },
  session_expired: { status: 401, message: "Сессия истекла. Войдите снова." },
  invalid_credentials: { status: 401, message: "Неверная почта или пароль." },
  invalid_email: { status: 400, message: "Проверьте адрес электронной почты." },
  weak_password: { status: 400, message: "Пароль должен быть не короче 8 символов и содержать буквы и цифры." },
  same_password: { status: 400, message: "Новый пароль совпадает с текущим." },
  email_taken: { status: 409, message: "Аккаунт с этой почтой уже существует." },
  invalid_password: { status: 403, message: "Неверный пароль." },
  invalid_recovery: { status: 403, message: "Почта или ключ восстановления не подходят." },
  // The password change itself succeeded; only ending the other sessions failed.
  password_changed_sessions_active: {
    status: 503,
    message: "Пароль изменён, но завершить сеансы на других устройствах не удалось. Нажмите «Выйти на всех устройствах».",
  },

  // Profile & onboarding
  onboarding_required: { status: 409, message: "Сначала заполните профиль." },
  username_invalid: { status: 400, message: "Имя пользователя: 3–20 символов, латиница, цифры и «_»." },
  username_reserved: { status: 400, message: "Это имя пользователя недоступно." },
  username_taken: { status: 409, message: "Это имя пользователя уже занято." },
  display_name_invalid: { status: 400, message: "Имя: от 2 до 40 букв." },
  city_required: { status: 400, message: "Выберите город." },
  city_not_found: { status: 404, message: "Город не найден." },
  club_not_found: { status: 404, message: "Клуб не найден." },
  club_name_invalid: { status: 400, message: "Название клуба: от 2 до 60 символов." },
  invalid_side: { status: 400, message: "Некорректная сторона корта." },
  invalid_hand: { status: 400, message: "Некорректная игровая рука." },
  invalid_playing_since: { status: 400, message: "Некорректный год начала игры." },
  bio_too_long: { status: 400, message: "Описание не длиннее 160 символов." },
  invalid_calibration: { status: 400, message: "Ответьте на все вопросы об уровне игры." },
  invalid_dna_self: { status: 400, message: "Оцените все шесть направлений." },
  invalid_avatar_path: { status: 400, message: "Не удалось сохранить фото." },
  invalid_image: { status: 400, message: "Поддерживаются только фотографии в формате JPEG." },
  player_not_found: { status: 404, message: "Игрок не найден." },

  // Matches
  match_not_found: { status: 404, message: "Матч не найден." },
  match_lineup_invalid: { status: 400, message: "В матче должно быть четыре игрока: по двое в каждой паре." },
  duplicate_player: { status: 400, message: "Один игрок не может быть в матче дважды." },
  creator_not_participant: { status: 400, message: "Вы должны быть участником матча." },
  invalid_match_type: { status: 400, message: "Выберите тип матча." },
  invalid_format: { status: 400, message: "Выберите формат матча." },
  invalid_score: { status: 400, message: "Проверьте счёт: он не соответствует правилам падела." },
  invalid_played_at: { status: 400, message: "Укажите дату матча." },
  played_at_in_future: { status: 400, message: "Дата матча не может быть в будущем." },
  played_at_too_old: { status: 400, message: "Рейтинговый матч можно внести в течение 14 дней, товарищеский — 90 дней." },
  duplicate_match: { status: 409, message: "Этот матч уже внесён." },
  too_many_ranked_matches: { status: 429, message: "У игрока слишком много рейтинговых матчей за день." },
  version_conflict: { status: 409, message: "Матч изменился. Проверьте актуальный счёт." },
  match_locked: { status: 409, message: "Матч уже подтверждён и не может быть изменён." },
  match_closed: { status: 409, message: "Матч отменён или истёк срок подтверждения." },
  creator_cannot_dispute: { status: 400, message: "Автор матча может изменить или отменить его." },
  invalid_dispute_reason: { status: 400, message: "Укажите причину несогласия." },
  dispute_comment_too_long: { status: 400, message: "Комментарий не длиннее 140 символов." },
  match_not_confirmed: { status: 409, message: "Оценки доступны после подтверждения матча." },
  feedback_window_closed: { status: 409, message: "Оценить игроков можно в течение 14 дней после матча." },
  invalid_feedback_target: { status: 400, message: "Оценивать можно только других участников матча." },
  invalid_feedback: { status: 400, message: "До двух сильных сторон и одна зона роста на игрока." },

  // Coaches & admin
  not_a_coach: { status: 403, message: "Оценки доступны только подтверждённым тренерам." },
  cannot_assess_self: { status: 400, message: "Нельзя оценить самого себя." },
  invalid_assessment: { status: 400, message: "Оцените все шесть направлений по шкале 0–7 с шагом 0,5." },
  assessment_too_soon: { status: 429, message: "Этого игрока можно оценить снова через 24 часа." },
  invalid_coach_application: { status: 400, message: "Заполните опыт и расскажите о себе (от 20 символов)." },
  coach_revoked: { status: 403, message: "Статус тренера был отозван." },
  application_not_found: { status: 404, message: "Заявка не найдена." },
};

export function specFor(code: string): ErrorSpec {
  return SPECS[code] ?? SPECS.internal!;
}

export function isKnownCode(code: string): boolean {
  return code in SPECS;
}

export function apiError(code: string, detail?: string): ApiError {
  return new ApiError(specFor(code).status, isKnownCode(code) ? code : "internal", detail);
}

export function errorBody(err: ApiError): { error: { code: string; message: string } } {
  return { error: { code: err.code, message: specFor(err.code).message } };
}
