# Nintendo Price Watcher

Watch Nintendo eShop prices (via [Deku Deals](https://www.dekudeals.com/)), set a target, get notified when it hits. Same workflow as Steam Price Watcher — chip on the workspace bar shows deals on target.

## Usage

Enable in **Settings → Plugins**, click the chip to open the panel. Search Switch games, add to watchlist, pick eShop region and check interval.

Data: `~/.config/alwm/plugins/dev.alwm.nintendo-price-watcher.json`

Prices and search scrape public Deku Deals pages (unofficial; may break if their HTML changes). Search expands each hit with **Included In** editions (Deluxe / Special / Complete) so eShop version branches appear alongside the base SKU.

## License

GPL-3.0 — same as [ALWM](../../LICENSE).
