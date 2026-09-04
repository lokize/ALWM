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