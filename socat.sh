#!/bin/bash
# 多功能 socat 转发脚本
# 支持 TCP/UDP 转发、systemd 服务管理及防火墙自动配置

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 检查是否为 root 用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 用户运行此脚本！${NC}"
    exit 1
fi

# 检查 socat 是否已安装
if ! command -v socat &> /dev/null; then
    echo -e "${YELLOW}socat 未安装，正在安装...${NC}"
    apt-get update >/dev/null 2>&1 || yum update -y >/dev/null 2>&1
    apt-get install socat -y >/dev/null 2>&1 || yum install socat -y >/dev/null 2>&1
    
    if ! command -v socat &> /dev/null; then
        echo -e "${RED}安装失败，请手动安装 socat！${NC}"
        exit 1
    fi
    echo -e "${GREEN}socat 安装成功！${NC}"
fi

# 检测防火墙类型
detect_firewall() {
    if command -v ufw &> /dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &> /dev/null; then
        echo "firewalld"
    elif command -v iptables &> /dev/null; then
        echo "iptables"
    else
        echo "none"
    fi
}

# 添加防火墙规则
add_firewall_rule() {
    local proto=$1
    local port=$2
    local firewall=$(detect_firewall)
    
    echo -e "${YELLOW}正在添加防火墙规则允许 ${proto^^} ${port} 端口...${NC}"
    
    case $firewall in
        ufw)
            ufw allow ${port}/${proto}
            ;;
        firewalld)
            firewall-cmd --zone=public --add-port=${port}/${proto} --permanent
            firewall-cmd --reload
            ;;
        iptables)
            iptables -A INPUT -p ${proto} --dport ${port} -j ACCEPT
            # 保存规则
            if command -v iptables-save &> /dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            fi
            ;;
        *)
            echo -e "${YELLOW}未检测到支持的防火墙，跳过防火墙规则设置。${NC}"
            ;;
    esac
}

# 删除防火墙规则
remove_firewall_rule() {
    local proto=$1
    local port=$2
    local firewall=$(detect_firewall)
    
    echo -e "${YELLOW}正在删除防火墙规则禁用 ${proto^^} ${port} 端口...${NC}"
    
    case $firewall in
        ufw)
            ufw delete allow ${port}/${proto}
            ;;
        firewalld)
            firewall-cmd --zone=public --remove-port=${port}/${proto} --permanent
            firewall-cmd --reload
            ;;
        iptables)
            iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT 2>/dev/null
            # 保存规则
            if command -v iptables-save &> /dev/null; then
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            fi
            ;;
        *)
            echo -e "${YELLOW}未检测到支持的防火墙，跳过防火墙规则清理。${NC}"
            ;;
    esac
}

# 服务名生成函数
generate_service_name() {
    local proto=$1
    local src_port=$2
    echo "socat-${proto}-${src_port}.service"
}

# 创建 systemd 服务
create_service() {
    local proto=$1
    local src_port=$2
    local dest_addr=$3
    local dest_port=$4
    local service_name=$(generate_service_name $proto $src_port)
    
    echo -e "${YELLOW}正在创建 systemd 服务: ${service_name}...${NC}"
    
    cat > /etc/systemd/system/${service_name} << EOF
[Unit]
Description=Socat ${proto^^} Forwarding Service (${src_port} → ${dest_addr}:${dest_port})
After=network.target

[Service]
ExecStart=/usr/bin/socat ${proto^^}4-LISTEN:${src_port},fork,reuseaddr ${proto^^}4:${dest_addr}:${dest_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    echo -e "${GREEN}服务 ${service_name} 创建成功！${NC}"
}

# 启动并启用服务
start_service() {
    local proto=$1
    local src_port=$2
    local service_name=$(generate_service_name $proto $src_port)
    
    echo -e "${YELLOW}正在启动服务 ${service_name}...${NC}"
    systemctl start ${service_name}
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}启动失败，请检查配置！${NC}"
        exit 1
    fi
    
    systemctl enable ${service_name}
    echo -e "${GREEN}服务 ${service_name} 已启动并设置为开机自启！${NC}"
}

# 显示单个服务状态
show_status() {
    local proto=$1
    local src_port=$2
    local service_name=$(generate_service_name $proto $src_port)
    
    echo -e "${YELLOW}服务 ${service_name} 状态：${NC}"
    systemctl status ${service_name} --no-pager
    
    echo -e "\n${YELLOW}端口监听状态：${NC}"
    netstat -tulpn | grep ":${src_port}" || echo -e "${RED}端口 ${src_port} 未监听！${NC}"
}

# 显示所有服务状态
show_all_status() {
    local proto=$1
    local proto_upper=$(echo $proto | tr '[:lower:]' '[:upper:]')
    
    echo -e "${GREEN}========== 所有 ${proto_upper} 转发服务状态 ==========${NC}"
    
    # 查找所有匹配的服务文件
    local services=$(ls /etc/systemd/system/socat-${proto}-*.service 2>/dev/null | grep -oP 'socat-\K[^.]*(?=\.service)')
    
    if [ -z "$services" ]; then
        echo -e "${YELLOW}未找到 ${proto_upper} 转发服务！${NC}"
        return
    fi
    
    echo -e "${BLUE}序号\t协议\t本地端口\t目标地址\t状态${NC}"
    echo -e "${BLUE}-----------------------------------------------------${NC}"
    
    local i=1
    for service in $services; do
        # 解析服务名获取端口
        local port=$(echo $service | grep -oP "${proto}-\K[0-9]+")
        
        # 获取服务描述中的目标地址
        local desc=$(systemctl show socat-${service}.service -p Description --value)
        local dest=$(echo $desc | grep -oP '\(\K[^)]+(?=\))')
        
        # 获取服务状态
        local active=$(systemctl is-active socat-${service}.service)
        if [ "$active" = "active" ]; then
            active="${GREEN}运行中${NC}"
        else
            active="${RED}已停止${NC}"
        fi
        
        echo -e "${i}\t${proto_upper}\t${port}\t\t${dest}\t${active}"
        i=$((i+1))
    done
    
    echo -e "${GREEN}-----------------------------------------------${NC}"
}

# 停止服务
stop_service() {
    echo -e "${YELLOW}===== 停止并禁用转发服务 ====${NC}"
    
    # 收集所有TCP和UDP服务
    local all_services=()
    local proto_list=("tcp" "udp")
    
    for proto in "${proto_list[@]}"; do
        local services=$(ls /etc/systemd/system/socat-${proto}-*.service 2>/dev/null | grep -oP 'socat-\K[^.]*(?=\.service)')
        for service in $services; do
            all_services+=("$proto $service")
        done
    done
    
    # 检查是否有服务
    if [ ${#all_services[@]} -eq 0 ]; then
        echo -e "${RED}没有找到任何转发服务！${NC}"
        sleep 2
        main_menu
    fi
    
    # 显示服务列表
    echo -e "${BLUE}序号\t协议\t本地端口\t目标地址\t状态${NC}"
    echo -e "${BLUE}-----------------------------------------------------${NC}"
    
    local i=1
    for service in "${all_services[@]}"; do
        read proto service_name <<< "$service"
        local port=$(echo $service_name | grep -oP "${proto}-\K[0-9]+")
        
        # 获取服务描述中的目标地址
        local desc=$(systemctl show socat-${service_name}.service -p Description --value)
        local dest=$(echo $desc | grep -oP '\(\K[^)]+(?=\))')
        
        # 获取服务状态
        local active=$(systemctl is-active socat-${service_name}.service)
        if [ "$active" = "active" ]; then
            active="${GREEN}运行中${NC}"
        else
            active="${RED}已停止${NC}"
        fi
        
        echo -e "${i}\t$(echo $proto | tr '[:lower:]' '[:upper:]')\t${port}\t\t${dest}\t${active}"
        i=$((i+1))
    done
    
    echo -e "${GREEN}-----------------------------------------------${NC}"
    echo -e "${YELLOW}0. 返回主菜单${NC}"
    
    # 获取用户选择
    read -p "请选择要停止的服务序号 [0-$((${#all_services[@]}))]: " choice
    
    # 验证选择
    if [ "$choice" = "0" ]; then
        main_menu
    fi
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#all_services[@]} ]; then
        echo -e "${RED}无效选择！${NC}"
        sleep 1
        stop_service
    fi
    
    # 获取对应的服务
    local selected_index=$(($choice - 1))
    read proto service_name <<< "${all_services[$selected_index]}"
    local port=$(echo $service_name | grep -oP "${proto}-\K[0-9]+")
    local service_file="socat-${service_name}.service"
    
    echo -e "${YELLOW}正在停止并禁用服务 ${service_file}...${NC}"
    systemctl stop ${service_file}
    systemctl disable ${service_file}
    rm -f /etc/systemd/system/${service_file}
    systemctl daemon-reload
    
    # 删除防火墙规则
    remove_firewall_rule $proto $port
    
    echo -e "${GREEN}服务 ${service_file} 已停止并禁用！${NC}"
    pause
    main_menu
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${GREEN}      Socat 转发脚本 v1.1                 ${NC}"
    echo -e "${GREEN}=====================================${NC}"
    echo -e "${YELLOW}1. 创建 TCP 端口转发${NC}"
    echo -e "${YELLOW}2. 创建 UDP 端口转发${NC}"
    echo -e "${YELLOW}3. 查看所有 TCP 转发服务${NC}"
    echo -e "${YELLOW}4. 查看所有 UDP 转发服务${NC}"
    echo -e "${YELLOW}5. 停止并禁用转发服务${NC}"
    echo -e "${YELLOW}6. 退出${NC}"
    echo -e "${GREEN}-------------------------------------${NC}"
    read -p "请选择操作 [1-6]: " choice
    
    case $choice in
        1) create_forward "tcp" ;;
        2) create_forward "udp" ;;
        3) show_all_status "tcp"; pause; main_menu ;;
        4) show_all_status "udp"; pause; main_menu ;;
        5) stop_service ;;
        6) exit 0 ;;
        *) echo -e "${RED}无效选择！${NC}" && sleep 1 && main_menu ;;
    esac
}

# 创建转发
create_forward() {
    local proto=$1
    local proto_upper=$(echo $proto | tr '[:lower:]' '[:upper:]')
    
    echo -e "${YELLOW}===== 创建 ${proto_upper} 端口转发 ====${NC}"
    read -p "请输入本地监听端口: " src_port
    read -p "请输入目标 IP 地址: " dest_addr
    read -p "请输入目标端口: " dest_port
    
    # 验证输入
    if ! [[ "$src_port" =~ ^[0-9]+$ && "$dest_port" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}端口号必须为数字！${NC}"
        sleep 1
        create_forward $proto
    fi
    
    # 检查端口是否已被占用
    if netstat -tulpn | grep -q ":${src_port}"; then
        echo -e "${RED}错误：端口 ${src_port} 已被占用！${NC}"
        echo -e "${YELLOW}占用情况：${NC}"
        netstat -tulpn | grep ":${src_port}"
        sleep 3
        create_forward $proto
    fi
    
    create_service $proto $src_port $dest_addr $dest_port
    start_service $proto $src_port
    # 添加防火墙规则
    add_firewall_rule $proto $src_port
    show_status $proto $src_port
    
    pause
    main_menu
}

# 暂停函数
pause() {
    read -p "按 Enter 键返回主菜单..."
}

# 执行主菜单
main_menu
