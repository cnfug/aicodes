#!/bin/bash

set -e

BACKUP_STORAGE="local"
KEEP_BACKUPS=5
SNAPSHOT_SIZE="4G"  # 可根据实际写入情况调整
BACKUP_BASE="/var/lib/vz"
BACKUP_DIR="$BACKUP_BASE/dump"
mkdir -p "$BACKUP_DIR"

# 压缩参数（压缩率优先）
ZSTD_LEVEL="-19"

perform_backup() {
  VMID="$1"
  DISK="$2"

  VOLID=$(qm config "$VMID" | grep "^$DISK:" | grep -oP '(local.*?:[^, ]+|/dev/[^ ,]+)')
  LVM_PATH=$(pvesm path "$VOLID" 2>/dev/null || echo "$VOLID")
  VG_NAME=$(lvs --noheadings -o vg_name "$LVM_PATH" | xargs)
  LV_NAME=$(lvs --noheadings -o lv_name "$LVM_PATH" | xargs)
  TS=$(date +%Y%m%d-%H%M%S)
  SAFE_DISK=$(echo "$DISK" | tr -c 'a-zA-Z0-9' '_')
  FILENAME="vzdump-qemu-${VMID}-${SAFE_DISK}-${TS}"
  BACKUP_FILE="$BACKUP_DIR/${FILENAME}.img.zst"
  CONF_FILE="$BACKUP_DIR/${FILENAME}.conf"
  SNAP_NAME="${LV_NAME}_snapshot"
  SNAP_PATH="/dev/$VG_NAME/$SNAP_NAME"

  echo "📸 创建快照 $SNAP_NAME ..."
  if lvdisplay "$SNAP_PATH" &>/dev/null; then
    echo "⚠️ 快照已存在，正在删除旧快照..."
    lvremove -f "$SNAP_PATH"
  fi
  lvcreate -s -n "$SNAP_NAME" -L "$SNAPSHOT_SIZE" "$LVM_PATH"

  echo "📆 压缩中：$BACKUP_FILE"
  dd if="$SNAP_PATH" bs=4M status=progress | zstd $ZSTD_LEVEL -T0 -o "$BACKUP_FILE"

  echo "🪢 删除快照..."
  lvremove -f "$SNAP_PATH"

  echo "📜 写入配置..."
  cat > "$CONF_FILE" <<EOF
{
  "type": "qemu",
  "volid": "$BACKUP_STORAGE:dump/${FILENAME}.img.zst",
  "size": $(stat -c %s "$BACKUP_FILE"),
  "ctime": $(date +%s),
  "disk": "$DISK",
  "vmid": "$VMID"
}
EOF

  echo "🗑 清理旧备份..."
  mapfile -t ALL_BACKUPS < <(ls -t "$BACKUP_DIR"/vzdump-qemu-${VMID}-${SAFE_DISK}-*.img.zst 2>/dev/null)
  mapfile -t SPECIAL_BACKUPS < <(printf "%s\n" "${ALL_BACKUPS[@]}" | grep -E 'vzdump-qemu-${VMID}-${SAFE_DISK}-[0-9]{8}-[0-9]{6}\.img\.zst' | while read -r file; do
    DAY_PART=$(basename "$file" | grep -oP '\\d{8}' | cut -c7-8)
    if [[ "$DAY_PART" =~ ^(01|05|10|15|20|25|30)$ ]]; then echo "$file"; fi
  done)
  mapfile -t NORMAL_BACKUPS < <(printf "%s\n" "${ALL_BACKUPS[@]}" | grep -vxF -f <(printf "%s\n" "${SPECIAL_BACKUPS[@]}"))

  printf "%s\n" "${NORMAL_BACKUPS[@]}" | tail -n +$((KEEP_BACKUPS + 1)) | while read -r oldimg; do
    echo "  - 删除普通备份 $oldimg"
    rm -f "$oldimg"
    rm -f "${oldimg%.img.zst}.conf"
  done

  printf "%s\n" "${SPECIAL_BACKUPS[@]}" | tail -n +3 | while read -r oldimg; do
    echo "  - 删除特殊日期备份 $oldimg"
    rm -f "$oldimg"
    rm -f "${oldimg%.img.zst}.conf"
  done

  echo "✅ 备份完成：$BACKUP_FILE"
}

perform_backup_interactive() {
  echo "📦 当前虚拟机列表："
  VM_RAW_LIST=$(qm list | awk 'NR>1')
  INDEX=1
  VMID_LIST=()
  while read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    echo "  [$INDEX] VMID: $VMID | 名称: $NAME"
    VMID_LIST+=($VMID)
    INDEX=$((INDEX + 1))
  done <<< "$VM_RAW_LIST"

  read -p "请输入要备份的虚拟机编号: " VM_CHOICE
  VMID=${VMID_LIST[$((VM_CHOICE - 1))]}
  if ! qm config "$VMID" &>/dev/null; then
    echo "❌ 虚拟机 $VMID 不存在"
    exit 1
  fi

  echo "💽 虚拟机 $VMID 的有效磁盘列表："
  DISK_ENTRIES=$(qm config "$VMID" | grep -E '^(scsi|sata|virtio|ide)[0-9]+:')
  VALID_DISKS=()
  INDEX=1
  while read -r line; do
    disk_name=$(echo "$line" | awk -F: '{print $1}')
    volid=$(echo "$line" | grep -oP '(local.*?:[^, ]+|/dev/[^ ,]+)')
    [ -z "$volid" ] && continue
    path=$(pvesm path "$volid" 2>/dev/null || echo "$volid")
    size=$(lsblk -b -no SIZE "$path" 2>/dev/null | awk '{ printf("%.2fG", $1/1024/1024/1024) }')
    echo "  [$INDEX] $disk_name → $volid (路径: $path, 大小: ${size:-未知})"
    VALID_DISKS+=("$disk_name")
    INDEX=$((INDEX + 1))
  done <<< "$DISK_ENTRIES"

  read -p "请输入要备份的磁盘编号: " SELECTION
  DISK="${VALID_DISKS[$((SELECTION - 1))]}"
  perform_backup "$VMID" "$DISK"
}

recover_backup() {
  echo "📁 可用备份文件（按虚拟机和磁盘分组）："
  declare -A VM_DISK_GROUPS
  declare -A INDEX_MAP
  INDEX=1
  for conf in $(ls "$BACKUP_DIR"/vzdump-qemu-*.conf 2>/dev/null | sort); do
    VMID=$(jq -r .vmid "$conf")
    DISK=$(jq -r .disk "$conf")
    CTIME=$(jq -r .ctime "$conf")
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M")
    GROUP_KEY="${VMID}|${DISK}"
    VM_DISK_GROUPS["$GROUP_KEY"]+="  [$INDEX] 时间: $TIME_FMT | 文件: $(basename "$conf")\n"
    INDEX_MAP[$INDEX]="$conf"
    INDEX=$((INDEX + 1))
  done

  if [ $INDEX -eq 1 ]; then echo "❌ 没有可用备份文件"; return; fi

  for key in "${!VM_DISK_GROUPS[@]}"; do
    VMID=$(echo "$key" | cut -d'|' -f1)
    DISK=$(echo "$key" | cut -d'|' -f2)
    echo "🔸 VMID: $VMID | 磁盘: $DISK"
    printf "%b" "${VM_DISK_GROUPS[$key]}"
  done

  read -p "请选择要恢复的备份编号: " SELECTED
  CONF_FILE="${INDEX_MAP[$SELECTED]}"
  [ -z "$CONF_FILE" ] && echo "❌ 选择无效" && return

  VMID=$(jq -r .vmid "$CONF_FILE")
  DISK=$(jq -r .disk "$CONF_FILE")
  VOLID=$(qm config "$VMID" | grep "^$DISK:" | grep -oP '(local.*?:[^, ]+|/dev/[^ ,]+)')
  LVM_PATH=$(pvesm path "$VOLID" 2>/dev/null || echo "$VOLID")
  IMAGE_FILE="${CONF_FILE%.conf}.img.zst"

  echo "🔄 正在恢复自 $IMAGE_FILE 到 $LVM_PATH ..."
  zstd -d -c "$IMAGE_FILE" | dd of="$LVM_PATH" bs=4M status=progress
  echo "✅ 恢复完成"
}

show_backup_list() {
  echo "📑 备份文件列表（按虚拟机和磁盘分组）："
  declare -A VM_DISK_GROUPS
  for conf in "$BACKUP_DIR"/vzdump-qemu-*.conf; do
    VMID=$(jq -r .vmid "$conf" 2>/dev/null)
    DISK=$(jq -r .disk "$conf" 2>/dev/null)
    SIZE=$(jq -r .size "$conf" 2>/dev/null)
    CTIME=$(jq -r .ctime "$conf" 2>/dev/null)
    [ -z "$VMID" ] && continue
    FILE="$(basename "$conf" .conf).img.zst"
    SIZE_FMT=$(printf "%.2fG" $(echo "$SIZE / 1024 / 1024 / 1024" | bc -l))
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M:%S")
    VM_DISK_GROUPS["$VMID|$DISK"]+="$TIME_FMT|$SIZE_FMT|$FILE\n"
  done
  for key in "${!VM_DISK_GROUPS[@]}"; do
    VMID="${key%%|*}"
    DISK="${key##*|}"
    echo -e "\n📊 VMID: $VMID | 磁盘: $DISK"
    echo "----------------------------------------"
    echo -e "备份时间\t\t| 大小\t| 备份文件"
    echo "----------------------------------------"
    printf "%b" "${VM_DISK_GROUPS[$key]}" | while IFS='|' read -r TIME SIZE FILE; do
      echo -e "$TIME\t$SIZE\t$FILE"
    done
  done
}

# 主程序交互
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请以 root 用户执行此脚本"
  exit 1
fi

if [ $# -eq 2 ]; then
  perform_backup "$1" "$2"
  exit 0
fi

echo "🛠 请选择操作："
echo "  [1] 备份虚拟磁盘"
echo "  [2] 恢复虚拟磁盘"
echo "  [3] 显示备份文件列表"
read -p "输入数字（1/2/3）: " ACTION

case "$ACTION" in
  1)
    perform_backup_interactive
    ;;
  2)
    recover_backup
    ;;
  3)
    show_backup_list
    ;;
  *)
    echo "❌ 无效选项"
    exit 1
    ;;
esac
