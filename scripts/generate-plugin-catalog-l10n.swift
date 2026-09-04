#!/usr/bin/env swift
// Writes plugins/*/l10n/{locale}.md — run: swift scripts/generate-plugin-catalog-l10n.swift
import Foundation

let langs = ["en", "zh-Hans", "hi", "es", "fr", "ar", "bn", "pt-BR", "ru", "ur"]

let plugins: [String: [String: String]] = [
    "github": githubReadmes(),
    "steam-price-watcher": steamReadmes(),
    "sample-clock": clockReadmes(),
]

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()

for (folder, byLang) in plugins {
    let l10nDir = root.appendingPathComponent("plugins/\(folder)/l10n", isDirectory: true)
    try FileManager.default.createDirectory(at: l10nDir, withIntermediateDirectories: true)
    for lang in langs {
        guard let text = byLang[lang] ?? byLang["en"] else {
            fputs("missing \(folder)/\(lang)\n", stderr)
            exit(1)
        }
        let dest = l10nDir.appendingPathComponent("\(lang).md")
        try text.write(to: dest, atomically: true, encoding: .utf8)
    }
    print("Wrote \(folder)/l10n/ (\(langs.count) locales)")
}

func githubReadmes() -> [String: String] {
    [
        "en": #"""
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
"""#,
        "pt-BR": #"""
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
"""#,
        "es": #"""
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
"""#,
        "fr": #"""
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
"""#,
        "zh-Hans": #"""
# GitHub（ALWM 插件）

在 ALWM 工作区栏中关注你的 GitHub 账户：

- 未读**通知**（提及、review、assign 等）
- 你仓库中的开放 **Pull requests**
- 待处理的 **Review requests**
- 分配给你的 **Issues**
- 最近的 **Stars**
- 新通知到达时的 macOS 原生提醒

## 设置

1. 在 **设置 → 插件** 中启用 **GitHub**。
2. 点击工作区栏上的芯片（或打开面板）。
3. 粘贴 [Personal Access Token](https://github.com/settings/tokens)（classic 或 fine-grained）。

### 推荐 scope（classic token）

| Scope | 用途 |
|-------|------|
| `notifications` | 列出并标记通知 |
| `repo` | 私有仓库中的 PR/issue |
| `read:user` | 个人资料与 `@me` 搜索 |

Fine-grained：**Notifications**（read）、**Issues**（read）、**Pull requests**（read）、**Metadata**（read）。

Token 保存在 `~/.config/alwm/plugins/dev.alwm.github.json`。请勿分享此文件。

## 使用

- **芯片：** GitHub 图标 + 未读数；悬停可轮播高亮项。
- **点击：** 打开面板（通知、PR、Issue、Star、设置）。
- **间隔：** 5–120 分钟（默认 15 分钟）。

## 隐私

所有请求通过你的 token 发往 `api.github.com`。不会向 ALWM 服务器发送任何数据。
"""#,
        "ru": #"""
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
"""#,
        "hi": #"""
# GitHub (ALWM प्लगइन)

ALWM workspace bar से अपना GitHub खाता देखें:

- न पढ़ी **notifications** (mentions, reviews, assign, आदि)
- आपके repos में खुले **pull requests**
- लंबित **review requests**
- आपको सौंपे **issues**
- हाल के **stars**
- नई notifications पर macOS अलर्ट

## सेटअप

1. **Settings → Plugins** में **GitHub** चालू करें।
2. workspace bar पर chip पर क्लिक करें (या panel खोलें)।
3. [Personal Access Token](https://github.com/settings/tokens) चिपकाएँ (classic या fine-grained)।

Token `~/.config/alwm/plugins/dev.alwm.github.json` में 저장 होता है। इस फ़ाइल को साझा न करें।

## उपयोग

- **Chip:** GitHub आइकन + unread गिनती; hover से highlights बदलें।
- **क्लिक:** panel खोलता है (Notifications, PRs, Issues, Stars, Settings)।
- **अंतराल:** 5–120 मिनट (डिफ़ॉल्ट 15)।

## गोपनीयता

सभी अनुरोध `api.github.com` पर आपके token के साथ जाते हैं। ALWM सर्वर को कुछ नहीं भेजा जाता।
"""#,
        "ar": #"""
# GitHub (إضافة ALWM)

راقب حساب GitHub من شريط مساحات العمل في ALWM:

- **إشعارات** غير مقروءة (إmentions وreviews وassign وغيرها)
- **طلبات سحب** مفتوحة في مستودعاتك
- **طلبات مراجعة** معلّقة
- **Issues** المسندة إليك
- **Stars** حديثة
- تنبيهات macOS عند وصول إشعارات جديدة

## الإعداد

1. في **الإعدادات → الإضافات**، فعّل **GitHub**.
2. انقر على الشريحة في شريط مساحات العمل (أو افتح اللوحة).
3. الصق [Personal Access Token](https://github.com/settings/tokens) (classic أو fine-grained).

يُخزَّن الرمز في `~/.config/alwm/plugins/dev.alwm.github.json`. لا تشارك هذا الملف.

## الاستخدام

- **الشريحة:** أيقونة GitHub + عدد غير المقروء؛ مرّر المؤشر للتنقل بين الم highlights.
- **النقر:** يفتح اللوحة (Notifications وPRs وIssues وStars والإعدادات).
- **الفاصل:** 5–120 دقيقة (الافتراضي 15).

## الخصوصية

جميع الطلبات إلى `api.github.com` برمزك. لا يُرسل شيء إلى خوادم ALWM.
"""#,
        "bn": #"""
# GitHub (ALWM প্লাগইন)

ALWM workspace bar থেকে GitHub অ্যাকাউন্ট মনিটর করুন:

- না পড়া **notifications** (mentions, reviews, assign ইত্যাদি)
- আপনার repo-তে খোলা **pull requests**
- মুলতুবি **review requests**
- আপনাকে দেওয়া **issues**
- সাম্প্রতিক **stars**
- নতুন notification এ macOS অ্যালার্ট

## সেটআপ

1. **Settings → Plugins**-এ **GitHub** চালু করুন।
2. workspace bar-এ chip-এ ক্লিক করুন (অথবা panel খুলুন)।
3. [Personal Access Token](https://github.com/settings/tokens) পেস্ট করুন।

Token `~/.config/alwm/plugins/dev.alwm.github.json`-এ সংরক্ষিত। ফাইল share করবেন না।

## ব্যবহার

- **Chip:** GitHub আইকন + unread সংখ্যা।
- **ক্লিক:** panel খোলে।
- **বিরতি:** 5–120 মিনিট (ডিফল্ট 15)।

## গোপনীয়তা

সব অনুরোধ `api.github.com`-এ আপনার token দিয়ে যায়। ALWM সার্ভারে কিছু পাঠানো হয় না।
"""#,
        "ur": #"""
# GitHub (ALWM پلگ ان)

ALWM workspace bar سے اپنا GitHub اکاؤنٹ دیکھیں:

- نہ پڑھی **notifications**
- آپ کے repos میں کھلے **pull requests**
- زیر التوا **review requests**
- آپ کو تفویض **issues**
- حالیہ **stars**
- نئی notifications پر macOS الرٹ

## سیٹ اپ

1. **Settings → Plugins** میں **GitHub** فعال کریں۔
2. workspace bar پر chip کلک کریں۔
3. [Personal Access Token](https://github.com/settings/tokens) چسپاں کریں۔

Token `~/.config/alwm/plugins/dev.alwm.github.json` میں محفوظ ہے۔

## استعمال

- **Chip:** GitHub آئیکن + unread گنتی۔
- **کلک:** panel کھولتا ہے۔
- **وقفہ:** 5–120 منٹ (طے شدہ 15)۔

## رازداری

تمام درخواستیں `api.github.com` پر آپ کے token کے ساتھ جاتی ہیں۔ ALWM سرورز کو کچھ نہیں بھیجا جاتا۔
"""#,
    ]
}

func steamReadmes() -> [String: String] {
    let en = #"""
# Steam Price Watcher

Port of the [Noctalia plugin](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) for ALWM.

Watch Steam prices, set a target, get notified when it hits. The workspace bar chip shows the deal (cover + name + price); hover cycles if several are on target.

## Usage

Enable in **Settings → Plugins**, click the chip to open the panel. Search, add games, pick currency and check interval. **Import from Noctalia** reads `~/.config/noctalia/plugins/steam-price-watcher/settings.json` if present.

Data: `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## License

GPL-3.0 — same as ALWM.
"""#
    return [
        "en": en,
        "pt-BR": #"""
# Steam Price Watcher

Port do plugin [Noctalia](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) para o ALWM.

Acompanhe preços na Steam, defina um alvo e receba alerta quando bater. O chip na barra mostra a oferta (capa + nome + preço); passe o mouse para alternar se vários estiverem no alvo.

## Uso

Ative em **Ajustes → Plugins** e clique no chip para abrir o painel. Busque, adicione jogos, escolha moeda e intervalo. **Importar do Noctalia** lê `~/.config/noctalia/plugins/steam-price-watcher/settings.json` se existir.

Dados: `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## Licença

GPL-3.0 — igual ao ALWM.
"""#,
        "es": #"""
# Steam Price Watcher

Puerto del plugin [Noctalia](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) para ALWM.

Sigue precios de Steam, fija un objetivo y recibe aviso al alcanzarlo. El chip muestra la oferta (portada + nombre + precio).

## Uso

Actívalo en **Ajustes → Plugins** y abre el panel desde el chip. Busca juegos, elige moneda e intervalo. **Importar de Noctalia** lee su JSON si existe.

Datos: `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## Licencia

GPL-3.0 — igual que ALWM.
"""#,
        "fr": #"""
# Steam Price Watcher

Portage du plugin [Noctalia](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) pour ALWM.

Suivez les prix Steam, fixez un objectif et recevez une alerte. La puce affiche l'offre (jaquette + nom + prix).

## Utilisation

Activez dans **Réglages → Plugins**, ouvrez le panneau via la puce. Recherchez, ajoutez des jeux, choisissez la devise et l'intervalle.

Données : `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## Licence

GPL-3.0 — identique à ALWM.
"""#,
        "zh-Hans": #"""
# Steam Price Watcher

面向 ALWM 的 [Noctalia 插件](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) 移植。

跟踪 Steam 价格、设置目标价并在达到时提醒。工作区栏芯片显示优惠（封面 + 名称 + 价格）。

## 使用

在 **设置 → 插件** 中启用，点击芯片打开面板。搜索、添加游戏、选择货币与检查间隔。

数据：`~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## 许可

GPL-3.0 — 与 ALWM 相同。
"""#,
        "ru": #"""
# Steam Price Watcher

Порт [плагина Noctalia](https://github.com/lokize/noctalia-plugins/tree/main/steam-price-watcher) для ALWM.

Отслеживайте цены Steam, задайте цель и получайте уведомление. Чип показывает предложение (обложка + название + цена).

## Использование

Включите в **Настройки → Плагины**, откройте панель через чип.

Данные: `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## Лицензия

GPL-3.0 — как у ALWM.
"""#,
        "hi": steamShort("Steam Price Watcher", "ALWM के लिए Noctalia प्लगइन का पोर्ट। Steam कीमतें देखें, लक्ष्य सेट करें, सूचना पाएँ। **Settings → Plugins** में चालू करें।"),
        "ar": steamShort("Steam Price Watcher", "منفذ إضافة Noctalia لـ ALWM. تابع أسعار Steam وحدّد هدفًا. فعّل من **الإعدادات → الإضافات**."),
        "bn": steamShort("Steam Price Watcher", "ALWM-এর জন্য Noctalia প্লাগইন। Steam দাম ট্র্যাক করুন, লক্ষ্য সেট করুন। **Settings → Plugins**-এ চালু করুন।"),
        "ur": steamShort("Steam Price Watcher", "ALWM کے لیے Noctalia پلگ ان۔ Steam قیمتیں دیکھیں، ہدف مقرر کریں۔ **Settings → Plugins** میں فعال کریں۔"),
    ]
}

func steamShort(_ title: String, _ body: String) -> String {
    """
# \(title)

\(body)

Data: `~/.config/alwm/plugins/dev.alwm.steam-price-watcher.json`

## License

GPL-3.0 — same as ALWM.
"""
}

func clockReadmes() -> [String: String] {
    let bodies: [String: String] = [
        "en": "HH:mm chip on the workspace bar.\n\nEnable under **Settings → Plugins**. Placement defaults to after workspaces; you can move it or pin it to one monitor.\n\nRefreshes about every 15 seconds.",
        "pt-BR": "Chip HH:mm na barra de workspaces.\n\nAtive em **Ajustes → Plugins**. A posição padrão é depois dos workspaces; você pode mover ou fixar em um monitor.\n\nAtualiza a cada ~15 segundos.",
        "es": "Chip HH:mm en la barra de workspaces.\n\nActívalo en **Ajustes → Plugins**. Por defecto va después de los workspaces.\n\nSe actualiza cada ~15 segundos.",
        "fr": "Puce HH:mm sur la barre de workspaces.\n\nActivez dans **Réglages → Plugins**. Par défaut après les workspaces.\n\nRafraîchissement ~15 s.",
        "zh-Hans": "工作区栏上的 HH:mm 芯片。\n\n在 **设置 → 插件** 中启用。默认在工作区之后。\n\n约每 15 秒刷新。",
        "ru": "Чип HH:mm на панели workspaces.\n\nВключите в **Настройки → Плагины**. По умолчанию после workspaces.\n\nОбновление ~15 с.",
        "hi": "workspace bar पर HH:mm chip। **Settings → Plugins** में चालू करें। ~15 सेकंड में refresh।",
        "ar": "شريحة HH:mm على شريط مساحات العمل. فعّل من **الإعدادات → الإضافات**. تحديث كل ~15 ثانية.",
        "bn": "workspace bar-এ HH:mm chip। **Settings → Plugins**-এ চালু করুন। ~15 সেকেন্ডে refresh।",
        "ur": "workspace bar پر HH:mm chip۔ **Settings → Plugins** میں فعال کریں۔ ~15 سیکنڈ refresh۔",
    ]
    var out: [String: String] = [:]
    for (lang, body) in bodies {
        let title: String
        switch lang {
        case "pt-BR": title = "Relógio"
        case "es": title = "Reloj"
        case "fr": title = "Horloge"
        case "zh-Hans": title = "时钟"
        case "ru": title = "Часы"
        case "hi": title = "घड़ी"
        case "ar": title = "ساعة"
        case "bn": title = "ঘড়ি"
        case "ur": title = "گھڑی"
        default: title = "Clock"
        }
        out[lang] = "# \(title)\n\n\(body)\n\nLicense: **GPL-3.0** (same as ALWM)."
    }
    return out
}
