# GitHub (ALWM plugin)

Monitor your GitHub account from the ALWM workspace bar:

- Unread **notifications** (mentions, reviews, assign, etc.)
- Open **pull requests** in your repositories
- Pending **review requests**
- **Issues** assigned to you
- Recent **stars**
- Native macOS alerts when new notifications arrive

## Setup

1. In **Settings → Plugins**, enable **GitHub**.
2. Click the chip on the workspace bar (or open the panel).
3. Paste a [Personal Access Token](https://github.com/settings/tokens) (classic or fine-grained).

### Recommended scopes (classic token)

| Scope | Use |
|-------|-----|
| `notifications` | List and mark notifications |
| `repo` | PRs/issues in private repositories |
| `read:user` | Profile and searches involving `@me` |

Fine-grained: **Notifications** (read), **Issues** (read), **Pull requests** (read), **Metadata** (read).

The token is stored in `~/.config/alwm/plugins/dev.alwm.github.json`. Do not share this file.

## Usage

- **Chip:** GitHub icon + unread count; hover to cycle highlights.
- **Click:** opens the panel (Notifications, PRs, Issues, Stars, Settings).
- **Interval:** 5–120 min (default 15 min).

## Privacy

All requests go to `api.github.com` with your token. Nothing is sent to ALWM servers.