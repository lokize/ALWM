# GitHub (plugin ALWM)

Supervisa tu cuenta de GitHub desde la barra de workspaces de ALWM:

- **Notificaciones** sin leer (menciones, reviews, assign, etc.)
- **Pull requests** abiertos en tus repositorios
- **Review requests** pendientes
- **Issues** asignadas a ti
- **Stars** recientes
- Alertas nativas de macOS cuando llegan notificaciones nuevas

## Configuración

1. En **Ajustes → Plugins**, activa **GitHub**.
2. Haz clic en el chip de la barra (o abre el panel).
3. Pega un [Personal Access Token](https://github.com/settings/tokens) (classic o fine-grained).

### Ámbitos recomendados (token classic)

| Ámbito | Uso |
|--------|-----|
| `notifications` | Listar y marcar notificaciones |
| `repo` | PRs/issues en repositorios privados |
| `read:user` | Perfil y búsquedas con `@me` |

Fine-grained: **Notifications** (read), **Issues** (read), **Pull requests** (read), **Metadata** (read).

El token se guarda en `~/.config/alwm/plugins/dev.alwm.github.json`. No compartas este archivo.

## Uso

- **Chip:** icono GitHub + contador sin leer; pasa el cursor para alternar destacados.
- **Clic:** abre el panel (Notificaciones, PRs, Issues, Stars, Ajustes).
- **Intervalo:** 5–120 min (predeterminado 15 min).

## Privacidad

Todas las peticiones van a `api.github.com` con tu token. Nada se envía a servidores de ALWM.