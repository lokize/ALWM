# GitHub (plugin ALWM)

Acompanhe sua conta GitHub na barra de workspaces do ALWM:

- **Notificações** não lidas (menções, reviews, assign, etc.)
- **Pull requests** abertos nos seus repositórios
- **Review requests** pendentes
- **Issues** atribuídas a você
- **Stars** recentes
- Alertas nativos do macOS quando chegam notificações novas

## Configuração

1. Em **Ajustes → Plugins**, ative **GitHub**.
2. Clique no chip na barra de workspaces (ou abra o painel).
3. Cole um [Personal Access Token](https://github.com/settings/tokens) (classic ou fine-grained).

### Escopos recomendados (token classic)

| Escopo | Uso |
|--------|-----|
| `notifications` | Listar e marcar notificações |
| `repo` | PRs/issues em repositórios privados |
| `read:user` | Perfil e buscas com `@me` |

Fine-grained: **Notifications** (read), **Issues** (read), **Pull requests** (read), **Metadata** (read).

O token fica em `~/.config/alwm/plugins/dev.alwm.github.json`. Não compartilhe este arquivo.

## Uso

- **Chip:** ícone GitHub + contagem não lidas; passe o mouse para alternar destaques.
- **Clique:** abre o painel (Notificações, PRs, Issues, Stars, Ajustes).
- **Intervalo:** 5–120 min (padrão 15 min).

## Privacidade

Todas as requisições vão para `api.github.com` com seu token. Nada é enviado aos servidores do ALWM.