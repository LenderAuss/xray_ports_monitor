#!/bin/bash

# Скрипт мониторинга трафика Xray по портам/инбаундам
# Показывает статистику использования трафика для каждого пользователя

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
TRAFFIC_CHAIN="XRAY_TRAFFIC"

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

# Функция для получения трафика порта в байтах
get_port_traffic_bytes() {
    local port=$1
    
    # Получаем входящий трафик (dport)
    local bytes_in=$(iptables -L $TRAFFIC_CHAIN -n -v -x 2>/dev/null | grep "dpt:$port" | awk '{sum+=$2} END {print sum}')
    
    # Получаем исходящий трафик (sport)
    local bytes_out=$(iptables -L $TRAFFIC_CHAIN -n -v -x 2>/dev/null | grep "spt:$port" | awk '{sum+=$2} END {print sum}')
    
    bytes_in=${bytes_in:-0}
    bytes_out=${bytes_out:-0}
    
    # Возвращаем: входящий исходящий общий
    local total=$((bytes_in + bytes_out))
    echo "$bytes_in $bytes_out $total"
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

# Функция для получения списка IP-адресов на порту
get_ip_list() {
    local port=$1
    
    # Получаем список уникальных IP
    ss -tn state established "( sport = :$port or dport = :$port )" 2>/dev/null | \
        awk 'NR>1 {print $5}' | \
        sed 's/:[0-9]*$//' | \
        sort -u
}

# Функция инициализации правил iptables
init_traffic_rules() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          🔧 ИНИЦИАЛИЗАЦИЯ МОНИТОРИНГА ТРАФИКА                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверяем существует ли цепочка
    if ! iptables -L $TRAFFIC_CHAIN -n >/dev/null 2>&1; then
        echo -e "${YELLOW}Создание цепочки $TRAFFIC_CHAIN...${NC}"
        iptables -N $TRAFFIC_CHAIN
        echo -e "${GREEN}✓ Цепочка создана${NC}"
    else
        echo -e "${GREEN}✓ Цепочка $TRAFFIC_CHAIN уже существует${NC}"
    fi
    
    # Проверяем правила INPUT/OUTPUT
    if ! iptables -C INPUT -j $TRAFFIC_CHAIN >/dev/null 2>&1; then
        iptables -I INPUT -j $TRAFFIC_CHAIN
        echo -e "${GREEN}✓ Добавлено правило INPUT → $TRAFFIC_CHAIN${NC}"
    else
        echo -e "${GREEN}✓ Правило INPUT уже существует${NC}"
    fi
    
    if ! iptables -C OUTPUT -j $TRAFFIC_CHAIN >/dev/null 2>&1; then
        iptables -I OUTPUT -j $TRAFFIC_CHAIN
        echo -e "${GREEN}✓ Добавлено правило OUTPUT → $TRAFFIC_CHAIN${NC}"
    else
        echo -e "${GREEN}✓ Правило OUTPUT уже существует${NC}"
    fi
    
    # Получаем все порты из конфига
    local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
    
    echo ""
    echo -e "${YELLOW}Добавление правил для портов...${NC}"
    
    local added_count=0
    
    # Добавляем правила для каждого порта
    for port in "${ports[@]}"; do
        local port_added=false
        
        # Входящий трафик
        if ! iptables -C $TRAFFIC_CHAIN -p tcp --dport "$port" >/dev/null 2>&1; then
            iptables -A $TRAFFIC_CHAIN -p tcp --dport "$port"
            port_added=true
        fi
        
        # Исходящий трафик
        if ! iptables -C $TRAFFIC_CHAIN -p tcp --sport "$port" >/dev/null 2>&1; then
            iptables -A $TRAFFIC_CHAIN -p tcp --sport "$port"
            port_added=true
        fi
        
        if [ "$port_added" = true ]; then
            echo -e "${GREEN}✓ Порт $port${NC}"
            added_count=$((added_count + 1))
        fi
    done
    
    if [ $added_count -eq 0 ]; then
        echo -e "${GREEN}✓ Все порты уже настроены${NC}"
    else
        echo -e "${GREEN}✓ Добавлено правил для $added_count портов${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}✅ Инициализация завершена${NC}"
    
    # Сохраняем правила
    if command -v iptables-save >/dev/null 2>&1; then
        echo ""
        read -p "Сохранить правила iptables? (y/n): " save_rules
        if [ "$save_rules" = "y" ] || [ "$save_rules" = "Y" ]; then
            if [ -f /etc/debian_version ]; then
                # Debian/Ubuntu
                iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                apt-get install -y iptables-persistent && iptables-save > /etc/iptables/rules.v4
                echo -e "${GREEN}✓ Правила сохранены${NC}"
            else
                # CentOS/RHEL
                service iptables save 2>/dev/null || \
                iptables-save > /etc/sysconfig/iptables
                echo -e "${GREEN}✓ Правила сохранены${NC}"
            fi
        fi
    fi
}

# Функция просмотра трафика
show_traffic() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📊 СТАТИСТИКА ТРАФИКА ПОЛЬЗОВАТЕЛЕЙ              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверяем наличие цепочки
    if ! iptables -L $TRAFFIC_CHAIN -n >/dev/null 2>&1; then
        echo -e "${RED}❌ Цепочка $TRAFFIC_CHAIN не найдена${NC}"
        echo -e "${YELLOW}Запустите: $0 init${NC}"
        return 1
    fi
    
    # Получаем список пользователей
    local tags=($(jq -r '.inbounds[].tag' $CONFIG_FILE))
    local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
    
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        return 0
    fi
    
    # Заголовок таблицы
    printf "${BLUE}%-5s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-8s${NC} ${CYAN}%-15s${NC} ${MAGENTA}%-15s${NC} ${WHITE}%-15s${NC} ${BLUE}%-8s${NC}\n" \
        "#" "Пользователь" "Порт" "Входящий" "Исходящий" "Всего" "IPs"
    echo "════════════════════════════════════════════════════════════════════════════════════════════════"
    
    local total_in=0
    local total_out=0
    local total_all=0
    local total_ips=0
    
    # Выводим информацию по каждому пользователю
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port="${ports[$i]}"
        local user_number=$((i + 1))
        
        # Получаем трафик
        read bytes_in bytes_out bytes_total <<< $(get_port_traffic_bytes "$port")
        
        # Получаем количество уникальных IP
        local unique_ips=$(get_unique_ips "$port")
        
        # Конвертируем в человеко-читаемый формат
        local in_human=$(bytes_to_human $bytes_in)
        local out_human=$(bytes_to_human $bytes_out)
        local total_human=$(bytes_to_human $bytes_total)
        
        # Суммируем
        total_in=$((total_in + bytes_in))
        total_out=$((total_out + bytes_out))
        total_all=$((total_all + bytes_total))
        total_ips=$((total_ips + unique_ips))
        
        # Цвет в зависимости от объема трафика
        local color=$GREEN
        if [ $bytes_total -gt 10737418240 ]; then  # > 10GB
            color=$RED
        elif [ $bytes_total -gt 1073741824 ]; then  # > 1GB
            color=$YELLOW
        fi
        
        # Цвет для IP в зависимости от количества
        local ip_color=$GREEN
        if [ $unique_ips -gt 10 ]; then
            ip_color=$RED
        elif [ $unique_ips -gt 5 ]; then
            ip_color=$YELLOW
        fi
        
        printf "%-5s %-15s %-8s ${color}%-15s${NC} ${color}%-15s${NC} ${color}%-15s${NC} ${ip_color}%-8s${NC}\n" \
            "$user_number" "$tag" "$port" "$in_human" "$out_human" "$total_human" "$unique_ips"
    done
    
    echo "════════════════════════════════════════════════════════════════════════════════════════════════"
    
    # Итого
    local total_in_human=$(bytes_to_human $total_in)
    local total_out_human=$(bytes_to_human $total_out)
    local total_all_human=$(bytes_to_human $total_all)
    
    printf "${CYAN}%-5s %-15s %-8s %-15s %-15s %-15s %-8s${NC}\n" \
        "" "ИТОГО:" "" "$total_in_human" "$total_out_human" "$total_all_human" "$total_ips"
    
    echo ""
}

# Функция мониторинга в реальном времени
monitor_traffic() {
    local interval=${1:-5}
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          📊 МОНИТОРИНГ ТРАФИКА В РЕАЛЬНОМ ВРЕМЕНИ             ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Интервал обновления: ${interval} секунд${NC}"
    echo -e "${YELLOW}Нажмите Ctrl+C для остановки${NC}"
    echo ""
    
    # Проверяем наличие цепочки
    if ! iptables -L $TRAFFIC_CHAIN -n >/dev/null 2>&1; then
        echo -e "${RED}❌ Цепочка $TRAFFIC_CHAIN не найдена${NC}"
        echo -e "${YELLOW}Запустите: $0 init${NC}"
        return 1
    fi
    
    local count=0
    
    while true; do
        count=$((count + 1))
        
        clear
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}📊 Обновление #${count} - $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        
        # Получаем список пользователей
        local tags=($(jq -r '.inbounds[].tag' $CONFIG_FILE))
        local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
        
        if [ ${#tags[@]} -eq 0 ]; then
            echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        else
            # Заголовок таблицы
            printf "${BLUE}%-5s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-8s${NC} ${CYAN}%-15s${NC} ${MAGENTA}%-15s${NC} ${WHITE}%-15s${NC} ${BLUE}%-8s${NC}\n" \
                "#" "Пользователь" "Порт" "Входящий" "Исходящий" "Всего" "IPs"
            echo "════════════════════════════════════════════════════════════════════════════════════════════════"
            
            local total_in=0
            local total_out=0
            local total_all=0
            local total_ips=0
            
            # Выводим информацию по каждому пользователю
            for i in "${!tags[@]}"; do
                local tag="${tags[$i]}"
                local port="${ports[$i]}"
                local user_number=$((i + 1))
                
                # Получаем трафик
                read bytes_in bytes_out bytes_total <<< $(get_port_traffic_bytes "$port")
                
                # Получаем количество уникальных IP
                local unique_ips=$(get_unique_ips "$port")
                
                # Конвертируем в человеко-читаемый формат
                local in_human=$(bytes_to_human $bytes_in)
                local out_human=$(bytes_to_human $bytes_out)
                local total_human=$(bytes_to_human $bytes_total)
                
                # Суммируем
                total_in=$((total_in + bytes_in))
                total_out=$((total_out + bytes_out))
                total_all=$((total_all + bytes_total))
                total_ips=$((total_ips + unique_ips))
                
                # Цвет в зависимости от объема трафика
                local color=$GREEN
                if [ $bytes_total -gt 10737418240 ]; then  # > 10GB
                    color=$RED
                elif [ $bytes_total -gt 1073741824 ]; then  # > 1GB
                    color=$YELLOW
                fi
                
                # Цвет для IP в зависимости от количества
                local ip_color=$GREEN
                if [ $unique_ips -gt 10 ]; then
                    ip_color=$RED
                elif [ $unique_ips -gt 5 ]; then
                    ip_color=$YELLOW
                fi
                
                printf "%-5s %-15s %-8s ${color}%-15s${NC} ${color}%-15s${NC} ${color}%-15s${NC} ${ip_color}%-8s${NC}\n" \
                    "$user_number" "$tag" "$port" "$in_human" "$out_human" "$total_human" "$unique_ips"
            done
            
            echo "════════════════════════════════════════════════════════════════════════════════════════════════"
            
            # Итого
            local total_in_human=$(bytes_to_human $total_in)
            local total_out_human=$(bytes_to_human $total_out)
            local total_all_human=$(bytes_to_human $total_all)
            
            printf "${CYAN}%-5s %-15s %-8s %-15s %-15s %-15s %-8s${NC}\n" \
                "" "ИТОГО:" "" "$total_in_human" "$total_out_human" "$total_all_human" "$total_ips"
        fi
        
        echo ""
        echo -e "${BLUE}⏳ Следующее обновление через ${interval} секунд...${NC}"
        
        sleep $interval
    done
}

# Функция просмотра трафика конкретного пользователя
show_user_traffic() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📊 ТРАФИК КОНКРЕТНОГО ПОЛЬЗОВАТЕЛЯ               ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Список пользователей
    local tags=($(jq -r '.inbounds[].tag' $CONFIG_FILE))
    local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
    
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        return 0
    fi
    
    echo "Список пользователей:"
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port="${ports[$i]}"
        echo "$((i+1)). $tag (порт: $port)"
    done
    
    echo ""
    read -p "Выберите пользователя: " choice
    
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#tags[@]} )); then
        echo -e "${RED}❌ Неверный выбор${NC}"
        return 1
    fi
    
    local index=$((choice - 1))
    local tag="${tags[$index]}"
    local port="${ports[$index]}"
    
    # Получаем метаданные
    local subscription=$(jq -r ".inbounds[$index].metadata.subscription // \"n/a\"" $CONFIG_FILE)
    local created_date=$(jq -r ".inbounds[$index].metadata.created_date // \"n/a\"" $CONFIG_FILE)
    
    # Получаем трафик
    read bytes_in bytes_out bytes_total <<< $(get_port_traffic_bytes "$port")
    
    # Получаем количество уникальных IP
    local unique_ips=$(get_unique_ips "$port")
    
    # Получаем список IP
    local ip_list=$(get_ip_list "$port")
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${CYAN}Пользователь: $tag${NC}"
    echo "════════════════════════════════════════════════════════════════"
    echo "Порт: $port"
    echo "Подписка: $subscription"
    echo "Создан: $created_date"
    echo "────────────────────────────────────────────────────────────────"
    echo -e "Входящий трафик:  ${CYAN}$(bytes_to_human $bytes_in)${NC}"
    echo -e "Исходящий трафик: ${MAGENTA}$(bytes_to_human $bytes_out)${NC}"
    echo -e "Всего:            ${WHITE}$(bytes_to_human $bytes_total)${NC}"
    echo "────────────────────────────────────────────────────────────────"
    echo -e "Уникальных IP:    ${BLUE}$unique_ips${NC}"
    
    if [ $unique_ips -gt 0 ]; then
        echo ""
        echo "Список подключенных IP-адресов:"
        echo "$ip_list" | nl -w2 -s'. '
    else
        echo ""
        echo -e "${YELLOW}Нет активных подключений${NC}"
    fi
    
    echo "════════════════════════════════════════════════════════════════"
    echo ""
}

# Функция просмотра всех активных IP-адресов
show_all_ips() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              🌐 ВСЕ АКТИВНЫЕ IP-АДРЕСА                        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Получаем список пользователей
    local tags=($(jq -r '.inbounds[].tag' $CONFIG_FILE))
    local ports=($(jq -r '.inbounds[].port' $CONFIG_FILE))
    
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        return 0
    fi
    
    local total_unique_ips=0
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port="${ports[$i]}"
        local user_number=$((i + 1))
        
        # Получаем количество уникальных IP
        local unique_ips=$(get_unique_ips "$port")
        
        if [ $unique_ips -gt 0 ]; then
            # Цвет для количества IP
            local ip_color=$GREEN
            if [ $unique_ips -gt 10 ]; then
                ip_color=$RED
            elif [ $unique_ips -gt 5 ]; then
                ip_color=$YELLOW
            fi
            
            echo -e "${CYAN}[$user_number] $tag${NC} (порт $port) - ${ip_color}$unique_ips IP${NC}"
            echo "────────────────────────────────────────────────────────────────"
            
            # Получаем список IP
            get_ip_list "$port" | nl -w2 -s'. '
            echo ""
            
            total_unique_ips=$((total_unique_ips + unique_ips))
        else
            echo -e "${CYAN}[$user_number] $tag${NC} (порт $port) - ${YELLOW}нет активных подключений${NC}"
            echo ""
        fi
    done
    
    echo "════════════════════════════════════════════════════════════════"
    echo -e "${CYAN}Всего уникальных IP: $total_unique_ips${NC}"
    echo ""
}

# Функция сброса статистики
reset_traffic() {
    echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Это сбросит всю статистику трафика!${NC}"
    read -p "Вы уверены? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Отменено${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Сброс счетчиков...${NC}"
    
    # Очищаем счетчики цепочки
    iptables -Z $TRAFFIC_CHAIN 2>/dev/null
    
    echo -e "${GREEN}✅ Статистика трафика сброшена${NC}"
}

# Функция удаления правил
remove_traffic_rules() {
    echo -e "${YELLOW}⚠️  ВНИМАНИЕ: Это удалит все правила мониторинга трафика!${NC}"
    read -p "Вы уверены? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        echo -e "${YELLOW}Отменено${NC}"
        return 0
    fi
    
    echo -e "${YELLOW}Удаление правил...${NC}"
    
    # Удаляем правила из INPUT и OUTPUT
    iptables -D INPUT -j $TRAFFIC_CHAIN 2>/dev/null
    iptables -D OUTPUT -j $TRAFFIC_CHAIN 2>/dev/null
    
    # Очищаем цепочку
    iptables -F $TRAFFIC_CHAIN 2>/dev/null
    
    # Удаляем цепочку
    iptables -X $TRAFFIC_CHAIN 2>/dev/null
    
    echo -e "${GREEN}✅ Правила мониторинга трафика удалены${NC}"
}

# Главное меню
show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📊 МОНИТОРИНГ ТРАФИКА XRAY                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo " 1) 🔧 Инициализировать мониторинг (первый запуск)"
    echo " 2) 📊 Показать статистику трафика"
    echo " 3) 📈 Мониторинг в реальном времени"
    echo " 4) 👤 Трафик конкретного пользователя"
    echo " 5) 🌐 Показать все активные IP-адреса"
    echo " 6) 🔄 Сбросить статистику"
    echo " 7) 🗑️  Удалить правила мониторинга"
    echo " 0) ❌ Выход"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1)
            init_traffic_rules
            ;;
        2)
            show_traffic
            ;;
        3)
            read -p "Интервал обновления в секундах (по умолчанию 5): " interval
            interval=${interval:-5}
            monitor_traffic "$interval"
            ;;
        4)
            show_user_traffic
            ;;
        5)
            show_all_ips
            ;;
        6)
            reset_traffic
            ;;
        7)
            remove_traffic_rules
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор${NC}"
            ;;
    esac
    
    if [ "$choice" != "3" ] && [ "$choice" != "0" ]; then
        echo ""
        read -p "Нажмите Enter для продолжения..."
        show_menu
    fi
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

if ! command -v iptables &> /dev/null; then
    echo -e "${RED}Ошибка: iptables не установлен${NC}"
    exit 1
fi

# Проверка конфига
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Ошибка: конфигурация Xray не найдена: $CONFIG_FILE${NC}"
    exit 1
fi

# Если запущен с аргументами
if [ $# -gt 0 ]; then
    case "$1" in
        init|setup)
            init_traffic_rules
            ;;
        show|stats|traffic)
            show_traffic
            ;;
        monitor|watch)
            interval=${2:-5}
            monitor_traffic "$interval"
            ;;
        user)
            show_user_traffic
            ;;
        ips|ip|addresses)
            show_all_ips
            ;;
        reset|clear)
            reset_traffic
            ;;
        remove|delete)
            remove_traffic_rules
            ;;
        *)
            echo "Использование: $0 [init|show|monitor|user|ips|reset|remove]"
            echo ""
            echo "Команды:"
            echo "  init           - инициализировать мониторинг"
            echo "  show           - показать статистику"
            echo "  monitor [sec]  - мониторинг в реальном времени"
            echo "  user           - трафик конкретного пользователя"
            echo "  ips            - показать все активные IP-адреса"
            echo "  reset          - сбросить статистику"
            echo "  remove         - удалить правила"
            echo ""
            echo "Без аргументов запускается интерактивное меню"
            exit 1
            ;;
    esac
else
    # Интерактивное меню
    show_menu
fi
