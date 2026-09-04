# GitHub (плагин ALWM)

Следите за аккаунтом GitHub на панели workspaces ALWM:

- Непрочитанные **уведомления** (упоминания, reviews, assign и т.д.)
- Открытые **pull requests** в ваших репозиториях
- Ожидающие **review requests**
- Назначенные вам **issues**
- Недавние **stars**
- Системные уведомления macOS о новых событиях

## Настройка

1. В **Настройки → Плагины** включите **GitHub**.
2. Нажмите на чип на панели (или откройте панель плагина).
3. Вставьте [Personal Access Token](https://github.com/settings/tokens) (classic или fine-grained).

### Рекомендуемые scopes (classic token)

| Scope | Назначение |
|-------|------------|
| `notifications` | Список и отметка уведомлений |
| `repo` | PR/issues в приватных репозиториях |
| `read:user` | Профиль и поиск с `@me` |

Fine-grained: **Notifications** (read), **Issues** (read), **Pull requests** (read), **Metadata** (read).

Токен хранится в `~/.config/alwm/plugins/dev.alwm.github.json`. Не передавайте этот файл.

## Использование

- **Чип:** иконка GitHub + счётчик непрочитанных; наведение переключает подсветку.
- **Клик:** открывает панель (Уведомления, PR, Issues, Stars, Настройки).
- **Интервал:** 5–120 мин (по умолчанию 15 мин).

## Конфиденциальность

Все запросы идут на `api.github.com` с вашим токеном. На серверы ALWM ничего не отправляется.