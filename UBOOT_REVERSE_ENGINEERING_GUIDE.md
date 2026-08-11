# 高通 U-Boot 逆向工程與 Memory Hack 位址提取指南

本指南說明當 Spectrum SAX1V1K / ASKEY RT5010W 設備上的 U-Boot 韌體雜湊值 (MD5 Hash，例如 `714b3fce2e5fea12cb58bfd0721d262d`) 尚未登錄於 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh) 的安全資料庫時，如何透過二進位逆向工程提取對應的記憶體修補 (Memory Hack) 與網卡初始化位址。

---

## 📌 逆向工程目標參數

在 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh) 的 `case "$uboot_hash" in` 中，新 U-Boot 版本的登錄格式如下：

```sh
  [MD5_HASH_VALUE])
    uboot_label="[U-Boot 版本描述與編譯日期]"
    uboot_hack="mw 4a91xxxx 0a000007 1; mw 4a91yyyy 0a000006 1"
    uboot_net_init="go 4a96zzzz"
    ;;
```

我們需要提取三個核心位址：
1. **`uboot_hack` 第一位址 (`4a91xxxx`)**：繞過 Bootenv 檢查的第一個 ARM64 分支判斷點。
2. **`uboot_hack` 第二位址 (`4a91yyyy`)**：繞過 Bootenv 檢查的第二個 ARM64 分支判斷點。
3. **`uboot_net_init` 進入點位址 (`4a96zzzz`)**：強制喚醒高通 EDMA 網卡驅動初始化函數的進入點。

---

## 🛠️ 逆向工程實務 SOP 步驟

### 步驟 1：在路由器備份出 Slot 0 的 U-Boot 二進位檔
在 OpenWrt SSH 終端機內執行：
```bash
dd if=/dev/mmcblk0p15 of=/tmp/uboot_slot0.bin
```
使用 `scp` 或 WinSCP 將 `/tmp/uboot_slot0.bin` (2 MB) 複製到電腦上。

---

### 步驟 2：選擇分析工具 (GUI 軟體 vs CLI/Python 自動掃描)

#### 🔹 選項 A：使用專案內建 Python 自動掃描工具 (推薦 ⭐️ - 0.01秒免安裝大體積 GUI)
本專案已內建全自動逆向特徵掃描腳本 **[`scan-uboot-hack.py`](scan-uboot-hack.py)**。將備份出的二進位檔放到專案目錄後直接執行：

```bash
python scan-uboot-hack.py uboot_slot0.bin
```

腳本會自動搜尋 ARM64 特徵碼 `0a000007` 與 `0a000006`，並在 **0.01 秒內** 自動計算實體記憶體位址，並印出可直接複製貼入 [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh) 的完整語法！

*（核心特徵碼掃描邏輯如下）：*
```python
BASE_ADDR = 0x4A600000
with open("uboot_slot0.bin", "rb") as f:
    data = f.read()

# 搜尋 ARM64 分支特徵位址 0a000007 (B +0x20)
for match in re.finditer(b"\x07\x00\x00\x0a", data):
    offset = match.start()
    print(f"Found match at memory address: 0x{BASE_ADDR + offset:X}")
```

#### 🔹 選項 B：使用 Ghidra / IDA Pro 圖形化介面分析
1. 開啟 **Ghidra** 或 **IDA Pro**，選擇新增專案並匯入 `uboot_slot0.bin`。
2. 處理器架構選擇：**ARM:LE:64:v8A (AArch64)**。
3. **關鍵設定**：載入基底位址 (Image Base Address) 必須設定為 **`0x4A600000`**。

---

### 步驟 3：定位 `uboot_hack` 兩組條件分支位址
1. 在 Ghidra 中搜尋關於 `bootcmd` 與環境變數載入檢查的條件分支。
2. 搜尋 ARM64 指令 `B` (Branch) 的二進位碼特徵 `0a000007` 與 `0a000006`。
3. 取得兩處判斷點的實體記憶體位址（格式通常為 `0x4A91XXXX` 與 `0x4A91YYYY`）。

---

### 步驟 4：定位 `uboot_net_init` 網卡初始化進入點
1. 在 Ghidra 的字串檢視器 (Defined Strings) 中搜尋 `ipq807x_edma_init` 或 `eth0` 網路介面相關字串。
2. 追蹤調用該字串的初始化函數開頭位址。
3. 取得函數入口點的記憶體位址（格式通常為 `0x4A96ZZZZ`）。

> [!NOTE]
> 若發現該 U-Boot 版本在 TFTP 啟動時已由原廠原生初始化網卡（例如 2024 年後的 `1.5.9` 版本），則 `uboot_net_init` 可留空為 `""`。

---

### 步驟 5：登錄至 `configure-uboot-dynamic.sh`

取得參數後，進行兩處修訂：

1. 在 `is_known_uboot_hash()` 函數中加入該 MD5 Hash：
   ```sh
   is_known_uboot_hash() {
     case "$1" in
       f3066582267c857e24097b4aecd3e9a1|\
       714b3fce2e5fea12cb58bfd0721d262d|\  # 新增此行
       ...
   ```

2. 在 `case "$uboot_hash" in` 區段中加入完整的分析結果：
   ```sh
     714b3fce2e5fea12cb58bfd0721d262d)
       uboot_label="1.3.3 [spf11.1_csu2] Jan 27 2021 (variant 714b)"
       uboot_hack="mw 4a91xxxx 0a000007 1; mw 4a91yyyy 0a000006 1"
       uboot_net_init="go 4a96zzzz"
       ;;
   ```

---

## 📄 關聯文件索引
* [`configure-uboot-dynamic.sh`](configure-uboot-dynamic.sh) - 動態解析與 U-Boot 配置主腳本
* [`DYNAMIC_UBOOT_GUIDE.md`](DYNAMIC_UBOOT_GUIDE.md) - 詳細功能與按鈕選單指南
* [`SKILL.md`](SKILL.md) - 專案維護經驗手冊
