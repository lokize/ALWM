# GitHub (plugin ALWM)

Suivez votre compte GitHub depuis la barre de workspaces ALWM :

- **Notifications** non lues (mentions, reviews, assign, etc.)
- **Pull requests** ouverts dans vos dépôts
- **Review requests** en attente
- **Issues** qui vous sont assignées
- **Stars** récentes
- Alertes macOS natives pour les nouvelles notifications

## Configuration

1. Dans **Réglages → Plugins**, activez **GitHub**.
2. Cliquez sur la puce de la barre (ou ouvrez le panneau).
3. Collez un [Personal Access Token](https://github.com/settings/tokens) (classic ou fine-grained).

### Scopes recommandés (token classic)

| Scope | Usage |
|-------|-------|
| `notifications` | Lister et marquer les notifications |
| `repo` | PRs/issues dans les dépôts privés |
| `read:user` | Profil et recherches avec `@me` |

Fine-grained : **Notifications** (read), **Issues** (read), **Pull requests** (read), **Metadata** (read).

Le token est stocké dans `~/.config/alwm/plugins/dev.alwm.github.json`. Ne partagez pas ce fichier.

## Utilisation

- **Puce :** icône GitHub + compteur non lu ; survolez pour faire défiler les surbrillances.
- **Clic :** ouvre le panneau (Notifications, PRs, Issues, Stars, Réglages).
- **Intervalle :** 5–120 min (15 min par défaut).

## Confidentialité

Toutes les requêtes vont vers `api.github.com` avec votre token. Rien n'est envoyé aux serveurs ALWM.