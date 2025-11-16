#!/bin/bash

# Скрипт мониторинга трафика Xray по портам
# Только режим реального времени - показывает трафик и уникальные IP

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
NC='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"

# Функция для конвертации байтов в человеко-читаемый формат
bytes_to_human() {
    local bytes=$1
    
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while (( $(echo "$size >= 1024" | bc -l) )) && [ $unit -lt 4 ]; do
        size=$(echo "scale=2; $size / 1024" | bc)
        unit=$((unit + 1))
    done
    
    printf "%.2f %s" "$size" "${units[$unit]}"
}

# Функция для получения статистики порта через iptables
get_port_stats() {
    local port=$1
    
    # Получаем байты через iptables
    local bytes_in=$(iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "dpt:$port" | awk '{sum+=$2} END {print sum}')
    local bytes_out=$(iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "spt:$port" | awk '{sum+=$2} END {print sum}')
    
    bytes_in=${bytes_in:-0}
    bytes_out=${bytes_out:-0}
    
    local total_bytes=$((bytes_in + bytes_out))
    
    echo "$total_bytes"
}

# Функция для получения уникальных IP-адресов на порту
get_unique_ips() {
    local port=$1
    
    # Получаем уникальные IP из активных соединений через ss
    local unique_count=$(ss -tn state established "( sport = :$port or dport = :$port )" 2>/dev/null | \
        awk 'NR>1 {print $5}' | \
        sed 's/:[0-9]*$//' | \
        sort -u | \
        wc -l)
    
    echo ${unique_count:-0}
}

# Функция мониторинга
monitor_traffic() {
    local interval_minutes=$1
    local interval_seconds=$((interval_minutes * 60))
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          📊 МОНИТОРИНГ ТРАФИКА ПОРТОВ XRAY                    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Интервал обновления: ${interval_minutes} минут (${interval_seconds} секунд)${NC}"
    echo -e "${YELLOW}Нажмите Ctrl+C для остановки${NC}"
    echo ""
    
    # Проверяем наличие iptables правил
    if ! iptables -L XRAY_TRAFFIC -n -v -x &>/dev/null; then
        echo -e "${YELLOW}⚠️  Правила iptables не найдены. Настройка...${NC}"
        echo ""
        
        # Создаем цепочку
        iptables -N XRAY_TRAFFIC 2>/dev/null
        iptables -I INPUT -j XRAY_TRAFFIC 2>/dev/null
        iptables -I OUTPUT -j XRAY_TRAFFIC 2>/dev/null
        
        # Добавляем правила для каждого порта
        local setup_ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
        for setup_port in "${setup_ports[@]}"; do
            iptables -A XRAY_TRAFFIC -p tcp --dport $setup_port 2>/dev/null
            iptables -A XRAY_TRAFFIC -p tcp --sport $setup_port 2>/dev/null
        done
        
        echo -e "${GREEN}✅ Правила iptables настроены${NC}"
        echo ""
        sleep 2
    fi
    
    local count=0
    
    while true; do
        count=$((count + 1))
        
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}📊 Обновление #${count} - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "${CYAN}   Интервал: ${interval_minutes} мин | Следующее через: ${interval_minutes} мин${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Получаем список пользователей
        local tags=($(jq -r '.inbounds[].tag' $CONFIG_FILE))
        local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
        
        if [ ${#tags[@]} -eq 0 ]; then
            echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        else
            # Заголовок таблицы
            printf "${BLUE}%-5s${NC} ${GREEN}%-20s${NC} ${YELLOW}%-10s${NC} ${WHITE}%-20s${NC} ${CYAN}%-10s${NC}\n" \
                "#" "Пользователь" "Порт" "Трафик" "IPs"
            echo "════════════════════════════════════════════════════════════════════════════"
            
            local total_traffic=0
            local total_ips=0
            
            # Выводим информацию по каждому пользователю
            for i in "${!tags[@]}"; do
                local tag="${tags[$i]}"
                local port="${ports[$i]}"
                local user_number=$((i + 1))
                
                # Получаем трафик
                local bytes=$(get_port_stats "$port")
                
                # Получаем количество уникальных IP
                local unique_ips=$(get_unique_ips "$port")
                
                # Конвертируем в человеко-читаемый формат
                local traffic_human=$(bytes_to_human $bytes)
                
                # Суммируем
                total_traffic=$((total_traffic + bytes))
                total_ips=$((total_ips + unique_ips))
                
                # Цвет в зависимости от объема трафика
                local color=$GREEN
                if [ $bytes -gt 10737418240 ]; then  # > 10GB
                    color=$RED
                elif [ $bytes -gt 1073741824 ]; then  # > 1GB
                    color=$YELLOW
                fi
                
                # Цвет для IP в зависимости от количества
                local ip_color=$GREEN
                if [ $unique_ips -gt 10 ]; then
                    ip_color=$RED
                elif [ $unique_ips -gt 5 ]; then
                    ip_color=$YELLOW
                elif [ $unique_ips -eq 0 ]; then
                    ip_color=$WHITE
                fi
                
                printf "%-5s %-20s %-10s ${color}%-20s${NC} ${ip_color}%-10s${NC}\n" \
                    "$user_number" "$tag" "$port" "$traffic_human" "$unique_ips"
            done
            
            echo "════════════════════════════════════════════════════════════════════════════"
            
            # Итого
            local total_traffic_human=$(bytes_to_human $total_traffic)
            
            printf "${CYAN}%-5s %-20s %-10s %-20s %-10s${NC}\n" \
                "" "ИТОГО:" "" "$total_traffic_human" "$total_ips"
        fi
        
        echo ""
        echo -e "${BLUE}⏳ Следующее обновление через ${interval_minutes} минут...${NC}"
        
        sleep $interval_seconds
    done
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Проверка наличия необходимых утилит
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Ошибка: jq не установлен. Установите: apt install jq${NC}"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo -e "${YELLOW}Установка bc...${NC}"
    apt-get update && apt-get install -y bc
fi

if ! command -v ss &> /dev/null; then
    echo -e "${RED}Ошибка: ss не установлен. Установите: apt install iproute2${NC}"
    exit 1
fi

# Проверка конфига
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Ошибка: конфигурация Xray не найдена: $CONFIG_FILE${NC}"
    exit 1
fi

# Запрос интервала
if [ $# -gt 0 ]; then
    interval=$1
else
    read -p "Интервал обновления в минутах (по умолчанию 1): " interval
    interval=${interval:-1}
fi

# Проверка что интервал число
if ! [[ "$interval" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo -e "${RED}Ошибка: интервал должен быть числом${NC}"
    exit 1
fi

# Запуск мониторинга
monitor_traffic "$interval"
