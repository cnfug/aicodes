#!/usr/bin/env bash
set -euo pipefail

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
NC="\033[0m"

STATE_DIR="/etc/port-fwd"
RULE_FILE="${STATE_DIR}/rules.tsv"
SERVICE_DIR="/etc/systemd/system"
SERVICE_PREFIX="port-fwd"
SET_PREFIX="portfwd"
WHIPTAIL_HEIGHT=20
WHIPTAIL_WIDTH=78

need_root() {
  [[ $EUID -eq 0 ]] || { echo -e "${RED}请用 root 运行${NC}"; exit 1; }
}

ensure_dirs() {
  mkdir -p "${STATE_DIR}"
  touch "${RULE_FILE}"
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y socat ipset iptables curl ca-certificates whiptail
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y socat ipset iptables curl ca-certificates newt
  else
    echo -e "${RED}不支持的包管理器${NC}"
    exit 1
  fi
}

have_whiptail() {
  command -v whiptail >/dev/null 2>&1
}

ui_msg() {
  local title="$1" msg="$2"
  if have_whiptail; then
    whiptail --title "$title" --msgbox "$msg" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH"
  else
    echo -e "${BLUE}${title}${NC}"
    echo -e "$msg"
    read -r -p "Enter继续..."
  fi
}

ui_yesno() {
  local title="$1" msg="$2"
  if have_whiptail; then
    whiptail --title "$title" --yesno "$msg" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH"
  else
    read -r -p "$msg [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
  fi
}

ui_input() {
  local title="$1" prompt="$2" default="${3:-}" val=""
  if have_whiptail; then
    val="$(whiptail --title "$title" --inputbox "$prompt" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH" "$default" 3>&1 1>&2 2>&3)" || return 1
    echo "$val"
  else
    read -r -p "$prompt " val
    echo "${val:-$default}"
  fi
}

valid_port() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && (( 1 <= $1 && $1 <= 65535 ))
}

svc_name() {
  echo "${SERVICE_PREFIX}-$1.service"
}

set_name() {
  echo "${SET_PREFIX}_$1"
}

region_name() {
  case "${1,,}" in
    bj) echo "北京市" ;;
    tj) echo "天津市" ;;
    sh) echo "上海市" ;;
    cq) echo "重庆市" ;;
    he|hb) echo "河北省" ;;
    sx1|shanxi) echo "山西省" ;;
    ln) echo "辽宁省" ;;
    jl) echo "吉林省" ;;
    hl|heilongjiang) echo "黑龙江省" ;;
    js) echo "江苏省" ;;
    zj) echo "浙江省" ;;
    ah) echo "安徽省" ;;
    fj) echo "福建省" ;;
    jx) echo "江西省" ;;
    sd) echo "山东省" ;;
    hn1|henan) echo "河南省" ;;
    hb1|hubei) echo "湖北省" ;;
    hn2|hunan) echo "湖南省" ;;
    gd) echo "广东省" ;;
    hi|hainan) echo "海南省" ;;
    sc) echo "四川省" ;;
    gz) echo "贵州省" ;;
    yn) echo "云南省" ;;
    sn|shanxi2) echo "陕西省" ;;
    gs) echo "甘肃省" ;;
    qh) echo "青海省" ;;
    tw) echo "台湾省" ;;
    nm) echo "内蒙古自治区" ;;
    gx) echo "广西壮族自治区" ;;
    xz) echo "西藏自治区" ;;
    nx) echo "宁夏回族自治区" ;;
    xj) echo "新疆维吾尔自治区" ;;
    hk) echo "香港特别行政区" ;;
    mo) echo "澳门特别行政区" ;;
    cn) echo "中国" ;;
    *) return 1 ;;
  esac
}

region_url() {
  case "${1,,}" in
    bj) echo "https://metowolf.github.io/iplist/data/cncity/110000.txt" ;;
    tj) echo "https://metowolf.github.io/iplist/data/cncity/120000.txt" ;;
    he|hb) echo "https://metowolf.github.io/iplist/data/cncity/130000.txt" ;;
    sx1|shanxi) echo "https://metowolf.github.io/iplist/data/cncity/140000.txt" ;;
    nm) echo "https://metowolf.github.io/iplist/data/cncity/150000.txt" ;;
    ln) echo "https://metowolf.github.io/iplist/data/cncity/210000.txt" ;;
    jl) echo "https://metowolf.github.io/iplist/data/cncity/220000.txt" ;;
    hl|heilongjiang) echo "https://metowolf.github.io/iplist/data/cncity/230000.txt" ;;
    sh) echo "https://metowolf.github.io/iplist/data/cncity/310000.txt" ;;
    js) echo "https://metowolf.github.io/iplist/data/cncity/320000.txt" ;;
    zj) echo "https://metowolf.github.io/iplist/data/cncity/330000.txt" ;;
    ah) echo "https://metowolf.github.io/iplist/data/cncity/340000.txt" ;;
    fj) echo "https://metowolf.github.io/iplist/data/cncity/350000.txt" ;;
    jx) echo "https://metowolf.github.io/iplist/data/cncity/360000.txt" ;;
    sd) echo "https://metowolf.github.io/iplist/data/cncity/370000.txt" ;;
    hn1|henan) echo "https://metowolf.github.io/iplist/data/cncity/410000.txt" ;;
    hb1|hubei) echo "https://metowolf.github.io/iplist/data/cncity/420000.txt" ;;
    hn2|hunan) echo "https://metowolf.github.io/iplist/data/cncity/430000.txt" ;;
    gd) echo "https://metowolf.github.io/iplist/data/cncity/440000.txt" ;;
    gx) echo "https://metowolf.github.io/iplist/data/cncity/450000.txt" ;;
    hi|hainan) echo "https://metowolf.github.io/iplist/data/cncity/460000.txt" ;;
    cq) echo "https://metowolf.github.io/iplist/data/cncity/500000.txt" ;;
    sc) echo "https://metowolf.github.io/iplist/data/cncity/510000.txt" ;;
    gz) echo "https://metowolf.github.io/iplist/data/cncity/520000.txt" ;;
    yn) echo "https://metowolf.github.io/iplist/data/cncity/530000.txt" ;;
    xz) echo "https://metowolf.github.io/iplist/data/cncity/540000.txt" ;;
    sn|shanxi2) echo "https://metowolf.github.io/iplist/data/cncity/610000.txt" ;;
    gs) echo "https://metowolf.github.io/iplist/data/cncity/620000.txt" ;;
    qh) echo "https://metowolf.github.io/iplist/data/cncity/630000.txt" ;;
    nx) echo "https://metowolf.github.io/iplist/data/cncity/640000.txt" ;;
    xj) echo "https://metowolf.github.io/iplist/data/cncity/650000.txt" ;;
    tw) echo "https://metowolf.github.io/iplist/data/country/TW/TW.txt" ;;
    hk) echo "https://metowolf.github.io/iplist/data/cncity/810000.txt" ;;
    mo) echo "https://metowolf.github.io/iplist/data/cncity/820000.txt" ;;
    cn) echo "https://metowolf.github.io/iplist/data/country/CN.txt" ;;
    *) return 1 ;;
  esac
}

load_region_to_file() {
  local code="${1:-}" url raw clean
  [[ -n "$code" ]] || return 1
  url="$(region_url "$code")" || return 1
  raw="/tmp/region.raw.$$"
  clean="/tmp/region.clean.$$"
  curl -fsSL "$url" -o "$raw"
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$raw" | sort -u > "$clean"
  rm -f "$raw"
  echo "$clean"
}

port_exists() {
  local port="$1" svc
  svc="$(svc_name "$port")"
  awk -F'\t' -v p="$port" '$1 == p {found=1} END {exit !found}' "$RULE_FILE" && return 0
  systemctl list-unit-files --type=service 2>/dev/null | grep -Fq "$svc" && return 0
  return 1
}

create_ipset_for_port() {
  local port="$1" clean="$2" s
  s="$(set_name "$port")"
  ipset destroy "$s" 2>/dev/null || true
  ipset create "$s" hash:net maxelem 200000 -exist
  while read -r net; do
    [[ -n "$net" ]] && ipset add "$s" "$net" -exist
  done < "$clean"
}

ensure_region_chain() {
  local port="$1" chain
  chain="region_${port}"
  iptables -N "$chain" 2>/dev/null || true
  iptables -F "$chain"
  iptables -D INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || true
  iptables -I INPUT 1 -p tcp --dport "$port" -j "$chain"
  echo "$chain"
}

apply_region_iptables_rules() {
  local port="$1" s chain
  s="$(set_name "$port")"
  chain="$(ensure_region_chain "$port")"
  iptables -A "$chain" -m set --match-set "$s" src -j ACCEPT
  iptables -A "$chain" -j DROP
}

apply_default_iptables_rules() {
  local port="$1"
  iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
  iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I INPUT 2 -p tcp --dport "$port" -j ACCEPT
}

remove_iptables_rules() {
  local port="$1" s chain
  s="$(set_name "$port")"
  chain="region_${port}"
  iptables -D INPUT -p tcp --dport "$port" -j "$chain" 2>/dev/null || true
  iptables -F "$chain" 2>/dev/null || true
  iptables -X "$chain" 2>/dev/null || true
  iptables -D INPUT -p tcp --dport "$port" -m set --match-set "$s" src -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p tcp --dport "$port" -j DROP 2>/dev/null || true
  iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
  ipset destroy "$s" 2>/dev/null || true
}

write_service() {
  local port="$1" dip="$2" dport="$3" svc
  svc="$(svc_name "$port")"
  cat > "${SERVICE_DIR}/${svc}" <<EOF
[Unit]
Description=Socat forward ${port} -> ${dip}:${dport}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat TCP4-LISTEN:${port},fork,reuseaddr TCP4:${dip}:${dport}
Restart=on-failure
RestartSec=5s
StartLimitIntervalSec=30
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$svc"
}

record_rule() {
  local port="$1" dip="$2" dport="$3" mode="$4" region_code="$5" region_name="$6"
  awk -F'\t' -v p="$port" '$1 != p {print $0}' "$RULE_FILE" > "${RULE_FILE}.tmp" || true
  mv "${RULE_FILE}.tmp" "$RULE_FILE" 2>/dev/null || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$port" "$dip" "$dport" "$mode" "$region_code" "$region_name" "enabled" >> "$RULE_FILE"
}

add_rule() {
  local port="$1" dip="$2" dport="$3" use_region="$4" region_code="${5:-}" clean mode="default" region_name="none"
  valid_port "$port" || { ui_msg "错误" "监听端口不合法"; return 1; }
  valid_port "$dport" || { ui_msg "错误" "目标端口不合法"; return 1; }
  if port_exists "$port"; then
    ui_msg "提示" "端口 ${port} 已存在，禁止重复添加"
    return 1
  fi
  if [[ "$use_region" == "yes" ]]; then
    mode="region"
    [[ -n "$region_code" ]] || { ui_msg "错误" "未选择地区代码"; return 1; }
    region_name="$(region_name "$region_code")" || { ui_msg "错误" "未知地区代码：${region_code}"; return 1; }
    clean="$(load_region_to_file "$region_code")" || { ui_msg "错误" "加载地区IP失败：${region_code}"; return 1; }
    create_ipset_for_port "$port" "$clean"
    rm -f "$clean"
    apply_region_iptables_rules "$port"
  else
    apply_default_iptables_rules "$port"
  fi
  write_service "$port" "$dip" "$dport"
  record_rule "$port" "$dip" "$dport" "$mode" "${region_code:-none}" "$region_name"
  ui_msg "完成" "已创建：${port} -> ${dip}:${dport}\n模式：${mode}\n地区：${region_code:-none} ${region_name}"
}

list_rules_ui() {
  local tmp="/tmp/portfwd_list.$$"
  {
    printf "PORT     DEST_IP          DEST     MODE      REGION_CODE REGION_NAME     ENABLED\n"
    [[ -s "$RULE_FILE" ]] && while IFS=$'\t' read -r port dip dport mode region_code region_name state; do
      [[ -n "${port:-}" ]] || continue
      [[ "$mode" == "region" ]] && m="REGION" || m="DEFAULT"
      printf "%-8s %-16s %-8s %-9s %-11s %-15s %-8s\n" "$port" "$dip" "$dport" "$m" "$region_code" "$region_name" "$state"
    done < "$RULE_FILE"
  } > "$tmp"
  if have_whiptail; then
    whiptail --title "规则列表" --textbox "$tmp" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH"
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

get_rule_ports() {
  mapfile -t RULE_PORTS < <(awk -F'\t' 'NF>=1 && $1 ~ /^[0-9]+$/ {print $1}' "$RULE_FILE" | sort -u)
}

choose_port() {
  local action="$1"
  get_rule_ports
  if [[ ${#RULE_PORTS[@]} -eq 0 ]]; then
    ui_msg "提示" "当前没有已创建端口"
    return 1
  fi
  if have_whiptail; then
    local menu_items=() i p choice
    for i in "${!RULE_PORTS[@]}"; do
      p="${RULE_PORTS[$i]}"
      menu_items+=("$p" "端口 $p")
    done
    menu_items+=("BACK" "返回主菜单")
    choice="$(whiptail --title "$action 端口" --menu "请选择要${action}的端口" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH" 12 "${menu_items[@]}" 3>&1 1>&2 2>&3)" || return 1
    [[ "$choice" == "BACK" ]] && return 1
    CHOSEN_PORT="$choice"
    return 0
  else
    echo
    echo "请选择要${action}的端口："
    select port in "${RULE_PORTS[@]}" "返回主菜单"; do
      case "$REPLY" in
        ''|*[!0-9]*) echo "请输入数字序号" ;;
        *)
          if [[ "$port" == "返回主菜单" ]]; then
            return 1
          elif [[ -n "${port:-}" ]]; then
            CHOSEN_PORT="$port"
            return 0
          else
            echo "无效选择"
          fi
          ;;
      esac
    done
  fi
}

show_status() {
  local port="$1" svc s mode region_code region_name type
  valid_port "$port" || { ui_msg "错误" "端口不合法"; return 1; }
  svc="$(svc_name "$port")"
  s="$(set_name "$port")"
  mode="$(awk -F'\t' -v p="$port" '$1==p {print $4}' "$RULE_FILE" | tail -n 1)"
  region_code="$(awk -F'\t' -v p="$port" '$1==p {print $5}' "$RULE_FILE" | tail -n 1)"
  region_name="$(awk -F'\t' -v p="$port" '$1==p {print $6}' "$RULE_FILE" | tail -n 1)"
  [[ "${mode:-default}" == "region" ]] && type="REGION" || type="DEFAULT"
  local tmp="/tmp/portfwd_status.$$"
  {
    echo "PORT: $port"
    echo "MODE: $type"
    echo "REGION_CODE: ${region_code:-none}"
    echo "REGION_NAME: ${region_name:-none}"
    systemctl is-active "$svc" >/dev/null 2>&1 && echo "SERVICE: active" || echo "SERVICE: inactive"
    systemctl is-enabled "$svc" >/dev/null 2>&1 && echo "ENABLED: yes" || echo "ENABLED: no"
    echo
    echo "iptables:"
    iptables -S INPUT | grep -- "--dport ${port}" || true
    echo
    echo "ipset:"
    ipset list "$s" 2>/dev/null | head -n 20 || echo "no ipset set"
  } > "$tmp"
  if have_whiptail; then
    whiptail --title "端口状态" --textbox "$tmp" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH"
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

disable_rule() {
  local port="$1" svc
  valid_port "$port" || { ui_msg "错误" "端口不合法"; return 1; }
  svc="$(svc_name "$port")"
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f "${SERVICE_DIR}/${svc}"
  systemctl daemon-reload
  remove_iptables_rules "$port"
  awk -F'\t' -v p="$port" '$1 != p {print $0}' "$RULE_FILE" > "${RULE_FILE}.tmp" || true
  mv "${RULE_FILE}.tmp" "$RULE_FILE" 2>/dev/null || true
  ui_msg "完成" "已禁用：${port}"
}

reload_rule() {
  local port="$1" svc
  valid_port "$port" || { ui_msg "错误" "端口不合法"; return 1; }
  svc="$(svc_name "$port")"
  if systemctl restart "$svc" 2>/dev/null; then
    ui_msg "完成" "已重载：${port}"
  else
    ui_msg "失败" "重载失败：服务不存在或已删除"
    return 1
  fi
}

remove_all() {
  mapfile -t ports < <(awk -F'\t' 'NF>=1 && $1 ~ /^[0-9]+$/ {print $1}' "$RULE_FILE" | sort -u)
  for port in "${ports[@]}"; do
    disable_rule "$port" || true
  done
  : > "$RULE_FILE"
  ui_msg "完成" "已清空全部规则"
}

show_region_menu() {
  local codes=(bj tj sh cq he nm ln jl hl js zj ah fj jx sd hn1 hb1 hn2 gd gx hi sc gz yn xz sn gs qh nx xj tw hk mo cn)
  local labels=("北京市" "天津市" "上海市" "重庆市" "河北省" "内蒙古自治区" "辽宁省" "吉林省" "黑龙江省" "江苏省" "浙江省" "安徽省" "福建省" "江西省" "山东省" "河南省" "湖北省" "湖南省" "广东省" "广西壮族自治区" "海南省" "四川省" "贵州省" "云南省" "西藏自治区" "陕西省" "甘肃省" "青海省" "宁夏回族自治区" "新疆维吾尔自治区" "台湾省" "香港特别行政区" "澳门特别行政区" "中国全境")
  local i choice
  if have_whiptail; then
    local menu_items=()
    for i in "${!codes[@]}"; do
      menu_items+=("${codes[$i]}" "${labels[$i]}")
    done
    choice="$(whiptail --title "选择地区" --menu "请选择地区代码" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH" 16 "${menu_items[@]}" 3>&1 1>&2 2>&3)" || return 1
    echo "$choice"
  else
    echo "可选地区代码："
    for i in "${!codes[@]}"; do
      printf "%s - %s\n" "${codes[$i]}" "${labels[$i]}"
    done
    read -r -p "请输入地区代码: " choice
    echo "$choice"
  fi
}

add_flow() {
  local port dip dport use_region region_code
  port="$(ui_input "新增转发" "监听端口:")" || return 1
  dip="$(ui_input "新增转发" "目标IP:")" || return 1
  dport="$(ui_input "新增转发" "目标端口:")" || return 1
  if ui_yesno "新增转发" "是否启用地区白名单？\n选Yes启用"; then
    use_region="yes"
    region_code="$(show_region_menu)" || return 1
  else
    use_region="no"
    region_code=""
  fi
  add_rule "$port" "$dip" "$dport" "$use_region" "$region_code"
}

menu() {
  while true; do
    local choice
    if have_whiptail; then
      choice="$(whiptail --title "Port Forward Manager" --menu "请选择功能" "$WHIPTAIL_HEIGHT" "$WHIPTAIL_WIDTH" 10 \
        "1" "安装依赖" \
        "2" "新增转发" \
        "3" "查看规则列表" \
        "4" "查看端口状态" \
        "5" "禁用端口" \
        "6" "重载端口" \
        "7" "清空全部规则" \
        "8" "退出" \
        3>&1 1>&2 2>&3)" || exit 0
    else
      echo
      echo -e "${GREEN}=== Port Forward Manager ===${NC}"
      echo "1) 安装依赖"
      echo "2) 新增转发"
      echo "3) 查看规则列表"
      echo "4) 查看端口状态"
      echo "5) 禁用端口"
      echo "6) 重载端口"
      echo "7) 清空全部规则"
      echo "8) 退出"
      read -r -p "请选择 [1-8]: " choice
    fi
    case "$choice" in
      1) install_deps; ui_msg "完成" "依赖已安装" ;;
      2) add_flow ;;
      3) list_rules_ui ;;
      4) if choose_port "查看"; then show_status "$CHOSEN_PORT"; fi ;;
      5) if choose_port "禁用"; then disable_rule "$CHOSEN_PORT"; fi ;;
      6) if choose_port "重载"; then reload_rule "$CHOSEN_PORT"; fi ;;
      7) if ui_yesno "确认" "确定要清空全部规则吗？"; then remove_all; fi ;;
      8) exit 0 ;;
      *) ui_msg "错误" "无效选择" ;;
    esac
  done
}

main() {
  need_root
  ensure_dirs
  menu
}

main "$@"
