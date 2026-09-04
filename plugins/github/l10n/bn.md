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