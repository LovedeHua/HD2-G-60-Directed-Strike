# 0.1 beta.1 — optional logging

Fixes the addon refusing to start when its diagnostic log cannot be created.
The logging service is now optional. Open, write, flush and close failures affect logging only.

Targeting rules, attack positions, native compatibility checks and ownership checks retain their existing behavior.
The runtime version is `0.5.20-experimental`.

Download **HD2-G60-Smart-Targeting-0.1-beta.1.zip** for installation; disable the previous G-60 package before deploying.
Requires Bingus Shared Loader API 1 with addon discovery (v15+).

Validated with portable logging regressions and the Windows fixture suite. This patch has not been separately tested in a live game.
Earlier gameplay results and the original 0.1 beta remain available; the original release's deployment hashes are preserved.

## 繁體中文

修正無法建立日誌時，整個模組會停止啟動的問題。
日誌現在是可選功能，缺少日誌服務、開檔失敗，以及寫入、刷新或關閉失敗，都不會中斷模組。

鎖敵規則、攻擊位置、遊戲程式碼相容性檢查與歸屬檢查沿用原有行為。
執行版本為 `0.5.20-experimental`。

安裝請使用 **HD2-G60-Smart-Targeting-0.1-beta.1.zip**，先停用舊版再部署。
已完成日誌故障回歸測試與 Windows 隔離測試；本次修正尚未重新進行遊戲實測。
