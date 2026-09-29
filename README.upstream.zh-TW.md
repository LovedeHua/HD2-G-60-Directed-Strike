# HD2 G-60 Smart Targeting

![G-60 Smart Targeting](assets/cover-16x9.png)

[English](README.md) · **0.1 beta.1** · [下載](https://github.com/etxp/HD2-G60-Smart-Targeting/releases)

讓 G-60 忽略一般小怪，依照順位追蹤指定蟲族重型單位，並在調整過的弱點附近引爆。
同一隻怪只會分配一顆手雷，避免多顆同時追同一個目標。

標記支援的蟲洞、飛龍巢、溢胞巢（孢子菇）或清除蟲卵任務的蟲卵後，手雷會優先攻擊它，
已經飛出去追怪的也會轉向。

## 目前規則

- 自動順位：**Bile Titan = Dragonroach > Impaler > Spore Charger > Charger Behemoth > Charger**。
- 只鎖定有特別設計過的敵人型號，一般小怪不會被鎖定。
- 同目標只分配一顆自己的手雷，直到那顆消失才釋放佔用；其他手雷找別的目標，沒有目標就盤旋。
- 自己標記的支援建物優先於怪物。最新的合格標記優先，畫面標記消失後仍保留記憶。
- 普通敵人的標記優先暫時停用。未標記的建物、隊友標記、地面座標標記不會觸發建物攻擊。
- 手雷抵達指定範圍才引爆；接近失敗會返回找目標，飛行滿 30 秒則直接移除。

怪物仍依遊戲提供的候選與視野機制取得，並非全地圖搜尋。
各單位的攻擊位置見[支援目標](docs/TARGETS.md)。

## 安裝

1. 退出遊戲，安裝 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)，需要 API 1、addon discovery（v15 以上）。
2. 從 Releases 下載 **HD2-G60-Smart-Targeting-0.1-beta.1.zip**，匯入模組管理器。原始碼 ZIP 不是安裝包。
3. 停用舊版 G-60，只啟用本版，完成 Purge / Deploy 後重新開啟遊戲。

解除安裝時停用模組、Purge / Deploy，再重新開啟遊戲即可。模組 GUID 與資源名稱保留原本設定。
日誌位於 loader 的記錄目錄，檔名為 `G60SmartTargeting.log`。
Beta.1 已將日誌改為可選，無法建立或寫入日誌時仍可啟動和運作。
日誌版本顯示 `0.5.20-experimental`。

## 測試狀態

目前已實測確認怪物篩選、順位與單顆分配、調整過的敵人攻擊位置，以及普通和大型蟲洞爆炸。
任務蟲卵已加入並通過隔離測試，但還沒有收到獨立的遊戲測試確認；飛龍巢與孢子菇的破壞效果也仍待確認。
不保證每次都能一顆擊殺或摧毀目標。

這是 beta 版，使用原遊戲函式並保留版本特徵、身分與歸屬檢查，沒有可執行記憶體修改、hook 或自製 DLL 注入。
原生生命週期與完整更新時序仍未證明，`native_lifetime_verified=false`。
遊戲更新後可能因檢查不符而停止啟用，不保證跨版本相容。

## 原始碼與建置

使用 Python 3.10 以上即可建置，不需遊戲檔案或外部封裝工具；LuaJIT 或 Lua 可執行離線測試。

```sh
python -B scripts/check.py
python -B scripts/build.py
```

詳細內容見[建置方式](docs/BUILDING.md)、[驗證紀錄](docs/VALIDATION.md)與[參與開發](CONTRIBUTING.md)。
作者：**etxp**。開發與封面編修使用 AI 協助。
自有程式與文件採 [MIT 授權](LICENSE)，遊戲資料和畫面權利見[第三方聲明](THIRD_PARTY_NOTICES.md)。
提供 [16:9](assets/cover-16x9.png) 與 [4:3](assets/cover-4x3.png) 兩款封面。
