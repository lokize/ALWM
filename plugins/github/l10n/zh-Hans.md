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