#!/bin/sh

# U-Boot configuration script for Spectrum SAX1V1K (Dynamic Sector Variant)
# Author: Lanchon (Original), Modified for Dynamic GPT Sector Resolution & POSIX sh Compatibility
# Date: 2026-08-10
# License: GPL v3 or newer

# 說明：
# 此腳本為方案 A 改寫版（完全相容 Busybox ash / POSIX sh）。
# 在設備無 Qualcomm Secure Boot 變磚風險的前提下，移除靜態 GPT Hash 鎖定，
# 改為動態讀取 eMMC 分割區起始扇區 (Start Sector)，同時保留 U-Boot 韌體版本 MD5 校驗與記憶體修補 (Memory Hack) 設定。

error() {
  echo
  printf "ERROR: %s\n" "$*"
  echo "press ctrl+c to stop..."
  cat > /dev/null
  echo
  exit 1
}

pause() {
  echo
  printf "WARNING: %s\n" "$*"
  echo "enter 'yes' to continue or ctrl+c to stop..."
  while true; do
    if [ "$( head -n1 )" = "yes" ]; then break; fi
  done
  echo
}

# 依據分割區標籤 (PARTNAME) 動態搜尋對應的 mmcblk0pX 及其起始扇區
# 支援帶有 "0:" 前綴的標籤 (例如 "0:HLOS" 與 "HLOS")
# 完全相容 POSIX / Busybox ash 語法
# 回傳: "mmcblk0pX 0xXXXX"
get_part_info_by_label() {
  target_label="$1"
  
  for p in /sys/class/block/mmcblk0p*; do
    [ -d "$p" ] || continue
    label="$( grep PARTNAME "$p/uevent" 2>/dev/null | cut -d= -f2 )"
    
    case "$label" in
      "$target_label" | "0:$target_label")
        dev_name="${p##*/}"
        start_dec="$( cat "$p/start" 2>/dev/null )"
        # POSIX 標準數字檢查
        case "$start_dec" in
          ''|*[!0-9]*) ;;
          *)
            printf "%s 0x%X" "$dev_name" "$start_dec"
            return 0
            ;;
        esac
        ;;
    esac
  done
  return 1
}

get_uboot_version_string() {
  if [ "$( strings -n10 "$1" | grep -E "U-Boot [0-9]+[.][0-9]+" | wc -l )" = "1" ]; then
    strings -n10 "$1" | grep -E "U-Boot [0-9]+[.][0-9]+"
  else
    echo "unknown"
  fi
}

# 判斷 Hash 是否為已知支援版本的輔助函式
is_known_uboot_hash() {
  case "$1" in
    63fcd6d91146ca0d689fbe9b91d34ae3|\
    f0320e776cfb0b5509ca9722eda42213|\
    714b3fce2e5fea12cb58bfd0721d262d|\
    f3066582267c857e24097b4aecd3e9a1|\
    ab709449c98f89cfa57e119b0f37b388|\
    d75be109e242ee8923cb45f1cb082f83|\
    7bc2f7766b270ea120495334cd1e5c56|\
    85ae38d2a62b124f431ba5baba6b42ad|\
    baf03dfc53dde25c54a351091ae48b84)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

configure_uboot() {

echo
echo "starting dynamic U-Boot configuration script..."
echo

# 0. 確保 fw_env 設定檔存在 (支援唯讀 rootfs / initramfs 環境)
FW_ENV_CONFIG="/etc/fw_env.config"
if [ ! -f "$FW_ENV_CONFIG" ]; then
  if ! echo "/dev/mmcblk0p14 0x0 0x40000 0x40000 1" > /etc/fw_env.config 2>/dev/null; then
    FW_ENV_CONFIG="/tmp/fw_env.config"
    echo "/dev/mmcblk0p14 0x0 0x40000 0x40000 1" > "$FW_ENV_CONFIG"
  fi
fi

fw_printenv() {
  command fw_printenv -c "$FW_ENV_CONFIG" "$@"
}

fw_setenv() {
  command fw_setenv -c "$FW_ENV_CONFIG" "$@"
}

# 1. 動態解析 GPT 分割區標籤與起始扇區 (Dynamic Label & Sector Resolution)

echo "resolving GPT partition start sectors by PARTLABEL..."

info_hlos="$( get_part_info_by_label "HLOS" )"
info_hlos_1="$( get_part_info_by_label "HLOS_1" )"
info_rsvd_5="$( get_part_info_by_label "rsvd_5" )"

dev_hlos="$( echo "$info_hlos" | cut -d' ' -f1 )"
sector_hlos="$( echo "$info_hlos" | cut -d' ' -f2 )"

dev_hlos_1="$( echo "$info_hlos_1" | cut -d' ' -f1 )"
sector_hlos_1="$( echo "$info_hlos_1" | cut -d' ' -f2 )"

dev_rsvd_5="$( echo "$info_rsvd_5" | cut -d' ' -f1 )"
sector_rsvd_5="$( echo "$info_rsvd_5" | cut -d' ' -f2 )"

if [ -z "$sector_hlos" ] || [ -z "$sector_hlos_1" ]; then
  error "could not resolve required partitions for HLOS / HLOS_1\ncheck your GPT partition labels"
fi

echo "  HLOS   (slot 0, ${dev_hlos:-"unknown"}) start sector : $sector_hlos"
echo "  HLOS_1 (slot 1, ${dev_hlos_1:-"unknown"}) start sector : $sector_hlos_1"

if [ -n "$sector_rsvd_5" ]; then
  echo "  rsvd_5 (recovery, ${dev_rsvd_5:-"unknown"}) start sector: $sector_rsvd_5"
else
  echo "  rsvd_5 (recovery) partition NOT found on this device!"
fi
echo

# 2. 驗證 U-Boot 版本與版本對應之 Memory Hack (Check U-Boot & Memory Hacks)

uboot_slot=""
if [ -e "/proc/boot_info/0:APPSBL/primaryboot" ]; then
  uboot_slot="$( cat "/proc/boot_info/0:APPSBL/primaryboot" )"
  if [ "$uboot_slot" != "0" ] && [ "$uboot_slot" != "1" ]; then
    uboot_slot=""
  fi
fi
if [ -z "$uboot_slot" ]; then
  uboot_slot="0"
fi

echo "U-Boot active slot: ${uboot_slot:-"unknown"}"

uboot0_hash="$( cat /dev/mmcblk0p15 | md5sum | cut -d' ' -f1 )"
uboot1_hash="$( cat /dev/mmcblk0p16 | md5sum | cut -d' ' -f1 )"

uboot_hash=""
uboot_part=""
uboot_copy_cmd=""

if [ "$uboot0_hash" != "$uboot1_hash" ]; then
  echo "WARNING: contents of U-Boot slots 0 and 1 do not match!"
  echo "  Slot 0 (p15) version: $( get_uboot_version_string /dev/mmcblk0p15 ) [MD5: $uboot0_hash]"
  echo "  Slot 1 (p16) version: $( get_uboot_version_string /dev/mmcblk0p16 ) [MD5: $uboot1_hash]"
  echo

  case "$uboot_slot" in
    0)
      uboot_hash="$uboot0_hash"
      uboot_part="/dev/mmcblk0p15"
      if ! is_known_uboot_hash "$uboot0_hash" && is_known_uboot_hash "$uboot1_hash"; then
        echo "Active Slot 0 has an UNKNOWN U-Boot hash ($uboot0_hash),"
        echo "but inactive Slot 1 has a KNOWN supported U-Boot hash ($uboot1_hash)."
        echo "We can synchronize Slot 1 -> Slot 0 with: dd if=/dev/mmcblk0p16 of=/dev/mmcblk0p15"
        pause "do you want to overwrite active Slot 0 with known Slot 1 U-Boot?"
        dd if=/dev/mmcblk0p16 of=/dev/mmcblk0p15 || error "failed to copy U-Boot from Slot 1 to Slot 0"
        uboot0_hash="$( cat /dev/mmcblk0p15 | md5sum | cut -d' ' -f1 )"
        uboot_hash="$uboot0_hash"
      else
        uboot_copy_cmd="dd if=/dev/mmcblk0p15 of=/dev/mmcblk0p16"
      fi
      ;;
    1)
      uboot_hash="$uboot1_hash"
      uboot_part="/dev/mmcblk0p16"
      if ! is_known_uboot_hash "$uboot1_hash" && is_known_uboot_hash "$uboot0_hash"; then
        echo "Active Slot 1 has an UNKNOWN U-Boot hash ($uboot1_hash),"
        echo "but inactive Slot 0 has a KNOWN supported U-Boot hash ($uboot0_hash)."
        echo "We can synchronize Slot 0 -> Slot 1 with: dd if=/dev/mmcblk0p15 of=/dev/mmcblk0p16"
        pause "do you want to overwrite active Slot 1 with known Slot 0 U-Boot?"
        dd if=/dev/mmcblk0p15 of=/dev/mmcblk0p16 || error "failed to copy U-Boot from Slot 0 to Slot 1"
        uboot1_hash="$( cat /dev/mmcblk0p16 | md5sum | cut -d' ' -f1 )"
        uboot_hash="$uboot1_hash"
      else
        uboot_copy_cmd="dd if=/dev/mmcblk0p16 of=/dev/mmcblk0p15"
      fi
      ;;
    *)
      error "U-Boot slots differ and the active slot could not be determined\ncontact support forum with this log"
      ;;
  esac
else
  echo "contents of U-Boot slots 0 and 1 match"
  uboot_hash="$uboot0_hash"
  uboot_part="/dev/mmcblk0p15"
fi
echo

echo "active U-Boot version string: $( get_uboot_version_string "$uboot_part" )"
echo "active U-Boot hash: $uboot_hash"
echo

uboot_label=""
uboot_hack=""
uboot_net_init=""
case "$uboot_hash" in
  63fcd6d91146ca0d689fbe9b91d34ae3)
    uboot_label="1.2.2 [spf11.1_cs] Jul 31 2020 (variant 63fc)"
    uboot_hack="mw 4a612880 0a000007 1; mw 4a613ec0 0a000006 1"
    uboot_net_init="go 4a9647cc"
    ;;
  f0320e776cfb0b5509ca9722eda42213)
    uboot_label="1.4.1 [spf11.4_cs] Jul 02 2021 (variant f032)"
    uboot_hack="mw 4a612880 0a000007 1; mw 4a614034 0a000006 1"
    uboot_net_init="go 4a9647cc"
    ;;
  714b3fce2e5fea12cb58bfd0721d262d)
    uboot_label="1.3.3 [spf11.1_csu2] Jan 27 2021 (variant 714b)"
    uboot_hack="mw 4a612880 0a000007 1; mw 4a613ebc 0a000006 1"
    uboot_net_init="go 4a9647cc"
    ;;
  f3066582267c857e24097b4aecd3e9a1)
    uboot_label="1.3.3 [spf11.1_csu2] Dec 09 2020 (variant f306)"
    uboot_hack="mw 4a910cd0 0a000007 1; mw 4a91dc6c 0a000006 1"
    uboot_net_init="go 4a96433c"
    ;;
  ab709449c98f89cfa57e119b0f37b388)
    uboot_label="1.3.3 [spf11.1_csu2] Jan 27 2021 (variant ab70)"
    uboot_hack="mw 4a911044 0a000007 1; mw 4a91dfdc 0a000006 1"
    uboot_net_init="go 4a9647cc"
    ;;
  d75be109e242ee8923cb45f1cb082f83)
    uboot_label="1.3.3 [spf11.1_csu2] Apr 22 2021 (variant d75b, untested)"
    uboot_hack="mw 4a910f88 0a000007 1; mw 4a91df24 0a000006 1"
    uboot_net_init="go 4a964714"
    ;;
  7bc2f7766b270ea120495334cd1e5c56)
    uboot_label="1.5.0 [spf11.4_csu1] Feb 24 2022 (untested)"
    uboot_hack="mw 4a9115a8 0a000007 1; mw 4a91e514 0a000006 1"
    uboot_net_init="go 4a966ba4"
    ;;
  85ae38d2a62b124f431ba5baba6b42ad)
    uboot_label="1.5.1 [spf11.4_csu2] Jun 15 2022"
    uboot_hack="mw 4a9115c8 0a000007 1; mw 4a91e534 0a000006 1"
    uboot_net_init="go 4a966bc4"
    ;;
  baf03dfc53dde25c54a351091ae48b84)
    uboot_label="1.5.9 [spf11.5_cs] Aug 19 2024 (untested)"
    uboot_hack="mw 4a912258 0a000007 1; mw 4a91f1c8 0a000006 1"
    uboot_net_init=""
    ;;
  *)
    error "unknown U-Boot hash\ndump U-Boot ($uboot_part) and contact support forum"
    ;;
esac
echo "found known U-Boot"
echo "U-Boot label: $uboot_label"
echo
echo

# 3. 同步非活躍槽位的 U-Boot (Update inactive U-Boot slot)

if [ -n "$uboot_copy_cmd" ]; then
  echo "the inactive copy of U-Boot in slot $(( 1 - uboot_slot )) must be updated"
  echo "to match the active one with the following command:"
  echo "$uboot_copy_cmd"
  echo
  pause "about to update the inactive copy of U-Boot"
  $uboot_copy_cmd || error "could not update the inactive copy of U-Boot\ncontact support forum with this log"
  echo "success"
  echo
fi

# 4. 配置 U-Boot 環境變數 (Configure U-Boot environment)

pause "about to configure U-Boot environment"

## Boot stages
fw_setenv boot_stage1 'echo "Hit Ctrl+C for shell..."; sleep 2 || exit; run boot_stage1_ok'
fw_setenv boot_stage1_ok 'run boot_stage2'

fw_setenv boot_stage2 'if itest *1022004 == 0; then echo "## Info: button pressed, boot paused"; base; sleep 1; while itest *1022004 == 0; do true; done; base; run boot_stage2_pause; else echo "## Info: button not pressed"; run boot_stage2_button_none; fi'
fw_setenv boot_stage2_pause 'echo "Click button for recovery, hold for active boot slot switch..."; while itest *1022004 != 0; do true; done; base; sleep 3; if itest *1022004 == 0; then run boot_stage2_button_hold; else run boot_stage2_button_click; fi'

fw_setenv boot_stage2_button_none 'run boot_stage3'
fw_setenv boot_stage2_button_click 'run boot_stage4'
fw_setenv boot_stage2_button_hold 'run boot_switch_active_slot && run boot_stage3'

fw_setenv boot_stage3 'echo "## Info: booting main OS..."; sleep 1 || exit; run boot_main; echo "## Error: main OS boot failed"; echo; run boot_stage3_fail'
fw_setenv boot_stage3_fail 'run boot_stage4'

fw_setenv boot_stage4 'echo "## Info: booting recovery OS..."; sleep 1 || exit; run boot_recovery; echo "## Error: recovery OS boot failed"; echo; run boot_stage4_fail'
fw_setenv boot_stage4_fail 'run boot_stage5'

fw_setenv boot_stage5 'echo "## Info: booting via TFTP..."; sleep 1 || exit; run boot_tftp; echo "## Error: TFTP boot failed"'

## Manual commands (使用動態解析之扇區位址)

fw_setenv boot_main 'if test "$boot_active_slot" = "1"; then SLOT=1; else SLOT=0; fi; run boot_slot'
fw_setenv boot_slot 'run boot_set_slot_$SLOT || exit; run boot_set_type_squashfs; run boot_hack; mmc read 44000000 "$KERNEL" 0x4000 && bootm'

# 使用動態解析得到的 $sector_hlos 與 $sector_hlos_1
fw_setenv boot_set_slot_0 "KERNEL=$sector_hlos; ROOTFS=/dev/mmcblk0p20; OVERLAY=rootfs_data"
fw_setenv boot_set_slot_1 "KERNEL=$sector_hlos_1; ROOTFS=/dev/mmcblk0p22; OVERLAY=rootfs_data_1"

fw_setenv boot_switch_active_slot 'if run boot_switch_active_slot_ram && saveenv; then echo "## Info: switched active boot slot to: $boot_active_slot"; else echo "## Error: could not switch active boot slot"; false; fi'
fw_setenv boot_switch_active_slot_ram 'if test "$boot_active_slot" = "1"; then setenv boot_active_slot 0; else setenv boot_active_slot 1; fi'
if [ -z "$( fw_printenv boot_active_slot 2>/dev/null )" ]; then
  fw_setenv boot_active_slot '0'
fi

# 如果有 rsvd_5 (Recovery OS) 則設定 recovery 讀取命令；否則寫入 #nop 避免無效讀取
if [ -n "$sector_rsvd_5" ]; then
  fw_setenv boot_recovery "run boot_set_type_initramfs; run boot_hack; mmc read 44000000 $sector_rsvd_5 0x10000 && bootm"
  fw_setenv boot_write_recovery_from_tftp "run boot_set_type_initramfs; run boot_set_ip; run boot_hack; run boot_net_init; tftpboot recovery.img || exit; echo; echo \"WILL WRITE RECOVERY IN 30s...\"; sleep 30 || exit; mmc write 44000000 $sector_rsvd_5 0x10000"
else
  fw_setenv boot_recovery 'echo "## Info: recovery partition (rsvd_5) not available"; false'
  fw_setenv boot_write_recovery_from_tftp '#nop'
fi

fw_setenv boot_tftp 'run boot_set_type_initramfs; run boot_set_ip; run boot_hack; run boot_net_init; tftpboot recovery.img && bootm'

## Shared auxiliary functions
fw_setenv boot_set_ip 'setenv ipaddr 1.2.3.1; setenv netmask 255.255.255.0; setenv serverip 1.2.3.4'
fw_setenv boot_set_type_initramfs 'setenv loadaddr 44000000; setenv bootargs console=ttyMSM0,115200n8 $EXTRAARGS'
fw_setenv boot_set_type_squashfs 'setenv loadaddr 44000000; setenv bootargs console=ttyMSM0,115200n8 root=$ROOTFS rootwait fstools_overlay_name=$OVERLAY $EXTRAARGS'
fw_setenv boot_dual_slot_support '2'

fw_setenv boot_hack "$uboot_hack"

if [ -n "$uboot_net_init" ]; then
  fw_setenv boot_net_init 'if test "$NET_INIT" != "1"; then '"$uboot_net_init"'; NET_INIT=1; echo; echo "## Info: waiting for network..."; sleep 5 || exit; fi'
else
  fw_setenv boot_net_init '#nop'
fi

echo "success"
echo

# 5. 啟用 bootcmd

bootcmd="run boot_stage1"
if [ "$( fw_printenv bootcmd 2>/dev/null )" != "bootcmd=$bootcmd" ]; then
  echo "activating bootcmd=$bootcmd..."
  pause "about to set 'bootcmd' to activate the new code"
  fw_setenv bootcmd "$bootcmd"
  echo "success"
  echo
fi

# 6. 清除舊版 U-Boot 變數
if fw_printenv setup_and_boot > /dev/null 2>&1; then
  pause "do you want to delete older boot variables? (recommended)"
  fw_setenv fix_uboot
  fw_setenv read_hlos_emmc
  fw_setenv set_custom_bootargs
  fw_setenv setup_and_boot
  echo "success"
  echo
fi

if fw_printenv boot_stage2_flag_read > /dev/null 2>&1; then
  pause "do you want to delete legacy stage2 boot flags? (recommended)"
  fw_setenv boot_queue_recovery
  fw_setenv boot_queue_recovery_cancel
  fw_setenv boot_stage2_flag_read
  fw_setenv boot_stage2_flag_write
  fw_setenv boot_stage2_choose
  fw_setenv boot_stage2_try
  fw_setenv boot_stage2_skip
  fw_setenv boot_stage2_ok
  fw_setenv boot_stage2_fail
  echo "success"
  echo
fi

echo "dynamic configuration completed successfully."
}

configure_uboot "$@"
