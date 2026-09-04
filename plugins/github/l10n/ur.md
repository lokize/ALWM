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