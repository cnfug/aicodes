#!/bin/bash

set -e

BACKUP_STORAGE="local"
KEEP_BACKUPS=5
SNAPSHOT_SIZE="4G"
BACKUP_BASE="/var/lib/vz"
BACKUP_DIR="$BACKUP_BASE/dump"
mkdir -p "$BACKUP_DIR"

ZSTD_LEVEL="-19"

# QEMU 备份函数
perform_backup_qemu() {
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
  lvremove -f "$SNAP_PATH" &>/dev/null || true
  lvcreate -s -n "$SNAP_NAME" -L "$SNAPSHOT_SIZE" "$LVM_PATH"

  echo "📦 压缩中：$BACKUP_FILE"
  dd if="$SNAP_PATH" bs=4M status=progress | zstd $ZSTD_LEVEL -T0 -o "$BACKUP_FILE"
  lvremove -f "$SNAP_PATH"

  echo "📜 写入配置：$CONF_FILE"
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

  echo "✅ 备份完成：$BACKUP_FILE"
}

# LXC 备份函数
perform_backup_lxc() {
  CTID="$1"
  TS=$(date +%Y%m%d-%H%M%S)
  LOGFILE="$BACKUP_DIR/lxc-${CTID}-${TS}.log"
  echo "📦 开始备份 LXC 容器 $CTID ..."
  # 修复：去掉 storage 和 dumpdir 同时使用的错误
  vzdump "$CTID" --mode snapshot --compress zstd --dumpdir "$BACKUP_DIR" --remove 0 2>&1 | tee "$LOGFILE"
  echo "✅ 容器 $CTID 备份完成（日志：$LOGFILE）"
}

# 交互式备份函数，自动识别 QEMU 或 LXC
perform_backup_interactive_combined() {
  echo "📋 当前系统中的虚拟机与容器："
  VM_LIST=$(qm list | awk 'NR>1')
  CT_LIST=$(pct list | awk 'NR>1')
  INDEX=1
  ID_MAP=()
  TYPE_MAP=()

  while read -r line; do
    VMID=$(echo "$line" | awk '{print $1}')
    NAME=$(echo "$line" | awk '{print $2}')
    echo "  [$INDEX] 🖥 VMID: $VMID | 名称: $NAME (QEMU)"
    ID_MAP[$INDEX]="$VMID"
    TYPE_MAP[$INDEX]="qemu"
    INDEX=$((INDEX + 1))
  done <<< "$VM_LIST"

  while read -r line; do
    CTID=$(echo "$line" | awk '{print $1}')
    STATUS=$(echo "$line" | awk '{print $2}')
    echo "  [$INDEX] 📦 CTID: $CTID | 名称: $STATUS (LXC)"
    ID_MAP[$INDEX]="$CTID"
    TYPE_MAP[$INDEX]="lxc"
    INDEX=$((INDEX + 1))
  done <<< "$CT_LIST"

  read -p "请输入要备份的编号: " CHOICE
  ID="${ID_MAP[$CHOICE]}"
  TYPE="${TYPE_MAP[$CHOICE]}"
  if [ "$TYPE" = "qemu" ]; then
    echo "💽 获取磁盘信息..."
    DISK_ENTRIES=$(qm config "$ID" | grep -E '^(scsi|sata|virtio|ide)[0-9]+:')
    INDEX=1
    VALID_DISKS=()
    while read -r line; do
      disk_name=$(echo "$line" | awk -F: '{print $1}')
      echo "  [$INDEX] $disk_name"
      VALID_DISKS+=("$disk_name")
      INDEX=$((INDEX + 1))
    done <<< "$DISK_ENTRIES"

    read -p "请选择要备份的磁盘编号: " DSEL
    DISK="${VALID_DISKS[$((DSEL - 1))]}"
    perform_backup_qemu "$ID" "$DISK"
  else
    perform_backup_lxc "$ID"
  fi
}

# 自动恢复函数，支持 QEMU 和 LXC
recover_auto() {
  echo "📁 可用备份文件列表（支持 QEMU 和 LXC）："
  declare -A INDEX_MAP
  INDEX=1

  for conf in $(ls "$BACKUP_DIR"/vzdump-qemu-*.conf 2>/dev/null | sort); do
    VMID=$(jq -r .vmid "$conf")
    DISK=$(jq -r .disk "$conf")
    CTIME=$(jq -r .ctime "$conf")
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M")
    echo "  [$INDEX] QEMU | VMID: $VMID | DISK: $DISK | 时间: $TIME_FMT"
    INDEX_MAP[$INDEX]="$conf"
    INDEX=$((INDEX + 1))
  done

  for file in $(ls "$BACKUP_DIR"/vzdump-lxc-*.tar.zst 2>/dev/null | sort); do
    CTID=$(basename "$file" | grep -oP 'vzdump-lxc-\K[0-9]+')
    CTIME=$(stat -c %Y "$file")
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M")
    INDEX_MAP[$INDEX]="$file"
    echo "  [$INDEX] LXC  | CTID: $CTID | 时间: $TIME_FMT"
    INDEX=$((INDEX + 1))
  done

  if [ $INDEX -eq 1 ]; then echo "❌ 没有可用备份文件"; return; fi

  read -p "请选择要恢复的备份编号: " SELECTED
  SELECTED_FILE="${INDEX_MAP[$SELECTED]}"

  if [[ "$SELECTED_FILE" == *.conf ]]; then
    CONF_FILE="$SELECTED_FILE"
    VMID=$(jq -r .vmid "$CONF_FILE")
    DISK=$(jq -r .disk "$CONF_FILE")
    VOLID=$(qm config "$VMID" | grep "^$DISK:" | grep -oP '(local.*?:[^, ]+|/dev/[^ ,]+)')
    LVM_PATH=$(pvesm path "$VOLID" 2>/dev/null || echo "$VOLID")
    IMAGE_FILE="${CONF_FILE%.conf}.img.zst"

    echo "🔄 正在恢复 QEMU VMID=$VMID 的磁盘 $DISK ..."
    zstd -d -c "$IMAGE_FILE" | dd of="$LVM_PATH" bs=4M status=progress
    echo "✅ 恢复完成"
  else
    FILE="$SELECTED_FILE"
    CTID=$(basename "$FILE" | grep -oP 'vzdump-lxc-\K[0-9]+')
    echo "🔄 正在恢复 LXC CTID=$CTID ..."
    if pct status "$CTID" &>/dev/null || qm status "$CTID" &>/dev/null; then
      echo "⚠️  原始 CTID=$CTID 已被占用，将强制恢复覆盖现有容器。"
      pct stop "$CTID" &>/dev/null || true
      pct destroy "$CTID"
    fi
    pct restore "$CTID" "$FILE" --storage local-lvm
    echo "✅ 容器恢复完成"
  fi
}

# 显示备份文件列表
show_backup_list() {
  echo "📑 QEMU 备份文件列表："
  for conf in "$BACKUP_DIR"/vzdump-qemu-*.conf; do
    [ -f "$conf" ] || continue
    VMID=$(jq -r .vmid "$conf")
    DISK=$(jq -r .disk "$conf")
    SIZE=$(jq -r .size "$conf")
    CTIME=$(jq -r .ctime "$conf")
    FILE="$(basename "$conf" .conf).img.zst"
    SIZE_FMT=$(printf "%.2fG" $(echo "$SIZE / 1024 / 1024 / 1024" | bc -l))
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M:%S")
    echo -e "\n📊 VMID: $VMID | 磁盘: $DISK"
    echo "----------------------------------------"
    echo -e "备份时间\t\t| 大小\t| 备份文件"
    echo "----------------------------------------"
    echo -e "$TIME_FMT\t$SIZE_FMT\t$FILE"
  done

  echo -e "\n📑 LXC 容器备份文件列表："
  for file in "$BACKUP_DIR"/vzdump-lxc-*.tar.zst; do
    [ -f "$file" ] || continue
    CTID=$(echo "$file" | grep -oP 'vzdump-lxc-\K[0-9]+')
    CTIME=$(stat -c %Y "$file")
    SIZE=$(stat -c %s "$file")
    SIZE_FMT=$(printf "%.2fG" $(echo "$SIZE / 1024 / 1024 / 1024" | bc -l))
    TIME_FMT=$(date -d "@$CTIME" "+%Y-%m-%d %H:%M:%S")
    echo -e "\n📦 CTID: $CTID"
    echo "----------------------------------------"
    echo -e "备份时间\t\t| 大小\t| 备份文件"
    echo "----------------------------------------"
    echo -e "$TIME_FMT\t$SIZE_FMT\t$(basename "$file")"
  done
}

if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 请以 root 用户执行此脚本"
  exit 1
fi

echo "🛠 请选择操作："
echo "  [1] 备份虚拟机或容器（自动识别）"
echo "  [2] 恢复虚拟机或容器（自动识别）"
echo "  [3] 显示备份文件列表"
read -p "输入数字（1/2/3）: " ACTION

case "$ACTION" in
  1)
    perform_backup_interactive_combined
    ;;
  2)
    recover_auto
    ;;
  3)
    show_backup_list
    ;;
  *)
    echo "❌ 无效选项"
    exit 1
    ;;
esac
