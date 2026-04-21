#!/bin/bash
# =============================================================================
# OSSEC - Cloudflare IP Ban (Active Response Script)
# Yazar       : Hamza Şamlıoğlu <hamza@priviasecurity.com>
# Versiyon    : 2.0.0
# Güncellenme : 2026-04-22
# =============================================================================
# KURULUM
# =============================================================================
# 1) Bu dosyayı kopyalayın:
#       cp cloudflare_ban.sh /var/ossec/active-response/bin/cloudflare-ban.sh
#       chmod +x /var/ossec/active-response/bin/cloudflare-ban.sh
#       chown root:ossec /var/ossec/active-response/bin/cloudflare-ban.sh
# 2) Cloudflare API Token oluşturun:
#       Cloudflare Dashboard → My Profile → API Tokens → Create Token
#       İzinler: Zone > Firewall Services > Edit
#                Zone > Zone > Read
#       (IP List modu için: Account > Account Filter Lists > Edit)
# 3) /var/ossec/etc/ossec.conf dosyanıza ekleyin:
#   <command>
#     <name>cloudflare-ban</name>
#     <executable>cloudflare-ban.sh</executable>
#     <timeout_allowed>yes</timeout_allowed>
#     <expect>srcip</expect>
#   </command>
#
#   <active-response>
#     <command>cloudflare-ban</command>
#     <location>server</location>
#     <rules_id>31151,31152,31153,31154,31161,31164,31165,31104,31100,5710,5712</rules_id>
#     <timeout>43200</timeout>
#   </active-response>
#
# 4) Aşağıdaki "YAPILANDIRMA" bölümünü düzenleyin.
#
# =============================================================================
# API YAPILANDIRMA
# =============================================================================

# Cloudflare API Token (Bearer)
# Dashboard > My Profile > API Tokens > Create Token
CF_API_TOKEN="CLOUDFLARE_API_TOKEN_BURAYA"

# Zone ID (Dashboard > domain seçin > Overview > sağ alt köşe)
CF_ZONE_ID="ZONE_ID_BURAYA"

# Account ID (Dashboard > herhangi bir domain > Overview > sağ alt köşe)
CF_ACCOUNT_ID="ACCOUNT_ID_BURAYA"

# =============================================================================
# OPSİYONEL YAPILANDIRMA
# =============================================================================

# Engelleme modu:
#   "block"     → Tamamen engelle (önerilen)
#   "challenge" → CAPTCHA göster (şüpheli trafik için)
#   "js_challenge" → JavaScript Challenge (bot trafik için)
#   "managed_challenge" → Cloudflare akıllı challenge
CF_ACTION="block"

# Kural oluşturma yöntemi:
#   "ip_access"  → IP Access Rules API (tüm planlarda çalışır, önerilen basit kurulum)
#   "list"       → WAF Custom Rules IP List (Pro+ plan, daha güçlü - CF_LIST_ID gerektirir)
CF_MODE="ip_access"

# [Sadece CF_MODE="list" için] Önceden oluşturulmuş IP listesinin ID'si
# Dashboard > Manage Account > Configurations > Lists > OSSEC-Blocked-IPs oluşturun
CF_LIST_ID=""

# Log dosyası
ACTIVE_RESPONSE_LOG="/var/ossec/logs/active-responses.log"

# Maksimum yeniden deneme sayısı (API geçici hata durumunda)
MAX_RETRIES=3

# Yeniden denemeler arasındaki bekleme süresi (saniye)
RETRY_DELAY=2

# =============================================================================
# SİSTEM DEĞİŞKENLERİ (değiştirmeyin)
# =============================================================================

LOCAL="$(dirname "$0")"
ACTION="$1"
USER="$2"
IP="$3"
SCRIPT_NAME="$(basename "$0")"
CF_API_BASE="https://api.cloudflare.com/client/v4"

# =============================================================================
# FONKSİYONLAR
# =============================================================================

# Yapılandırılmış loglama
log() {
    local SEVERITY="$1"
    local MSG="$2"
    local TIMESTAMP
    TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "${TIMESTAMP} [${SEVERITY}] ${SCRIPT_NAME}: ${MSG}" >> "${ACTIVE_RESPONSE_LOG}"
    if [ "${SEVERITY}" = "ERROR" ]; then
        echo "${TIMESTAMP} [${SEVERITY}] ${SCRIPT_NAME}: ${MSG}" >&2
    fi
}

# IP adresinin geçerli olup olmadığını kontrol et (IPv4 ve IPv6)
validate_ip() {
    local IP_ADDR="$1"

    # IPv4 kontrolü (CIDR dahil)
    if echo "${IP_ADDR}" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$'; then
        return 0
    fi

    # IPv6 kontrolü (CIDR dahil)
    if echo "${IP_ADDR}" | grep -qE '^([0-9a-fA-F:]+)(:[0-9a-fA-F]+)*(/[0-9]{1,3})?$'; then
        return 0
    fi

    return 1
}

# IPv6 adresini CIDR formatına dönüştür (Cloudflare zorunlu kılar)
normalize_ipv6() {
    local IP_ADDR="$1"
    # Eğer CIDR maskesi yoksa /128 ekle
    if echo "${IP_ADDR}" | grep -qE '^[0-9a-fA-F:]+$' && ! echo "${IP_ADDR}" | grep -q '/'; then
        echo "${IP_ADDR}/128"
    else
        echo "${IP_ADDR}"
    fi
}

# API isteği gönder (retry mekanizması ile)
cf_api_call() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local DATA="$3"
    local ATTEMPT=0
    local RESPONSE=""
    local HTTP_CODE=""

    while [ ${ATTEMPT} -lt ${MAX_RETRIES} ]; do
        ATTEMPT=$((ATTEMPT + 1))

        if [ -n "${DATA}" ]; then
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X "${METHOD}" \
                "${CF_API_BASE}${ENDPOINT}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --data "${DATA}" \
                --max-time 30 \
                --connect-timeout 10)
        else
            RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X "${METHOD}" \
                "${CF_API_BASE}${ENDPOINT}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                --max-time 30 \
                --connect-timeout 10)
        fi

        HTTP_CODE=$(echo "${RESPONSE}" | tail -n1)
        BODY=$(echo "${RESPONSE}" | head -n -1)

        # HTTP 200, 201 başarı; 429 rate limit (bekle ve tekrar dene)
        if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
            echo "${BODY}"
            return 0
        elif [ "${HTTP_CODE}" = "429" ]; then
            log "WARN" "API rate limit aşıldı. ${RETRY_DELAY}s bekleniyor... (Deneme ${ATTEMPT}/${MAX_RETRIES})"
            sleep "${RETRY_DELAY}"
        else
            log "WARN" "API yanıt kodu: ${HTTP_CODE}. Yanıt: ${BODY} (Deneme ${ATTEMPT}/${MAX_RETRIES})"
            if [ ${ATTEMPT} -lt ${MAX_RETRIES} ]; then
                sleep "${RETRY_DELAY}"
            fi
        fi
    done

    echo "${BODY}"
    return 1
}

# API yanıtının başarılı olup olmadığını kontrol et
check_api_success() {
    local RESPONSE="$1"
    echo "${RESPONSE}" | grep -q '"success":true'
    return $?
}

# =============================================================================
# IP ACCESS RULES MODU (CF_MODE="ip_access")
# =============================================================================

ip_access_add() {
    local TARGET_IP="$1"
    local NOTE="OSSEC Active Response | $(date '+%Y-%m-%d %H:%M:%S') | Otomatik engelleme"

    local DATA
    DATA=$(printf '{"mode":"%s","configuration":{"target":"ip","value":"%s"},"notes":"%s"}' \
        "${CF_ACTION}" "${TARGET_IP}" "${NOTE}")

    local RESPONSE
    RESPONSE=$(cf_api_call "POST" "/zones/${CF_ZONE_ID}/firewall/access_rules/rules" "${DATA}")

    if check_api_success "${RESPONSE}"; then
        local RULE_ID
        RULE_ID=$(echo "${RESPONSE}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        log "INFO" "IP Access Rule oluşturuldu | IP: ${TARGET_IP} | Aksiyon: ${CF_ACTION} | Kural ID: ${RULE_ID}"
        return 0
    else
        log "ERROR" "IP Access Rule oluşturulamadı | IP: ${TARGET_IP} | Yanıt: ${RESPONSE}"
        return 1
    fi
}

ip_access_delete() {
    local TARGET_IP="$1"

    # Önce mevcut kuralı bul
    local ENCODED_IP
    ENCODED_IP=$(printf '%s' "${TARGET_IP}" | sed 's|/|%2F|g')

    local RESPONSE
    RESPONSE=$(cf_api_call "GET" \
        "/zones/${CF_ZONE_ID}/firewall/access_rules/rules?mode=${CF_ACTION}&configuration_target=ip&configuration_value=${ENCODED_IP}&per_page=1" \
        "")

    if ! check_api_success "${RESPONSE}"; then
        log "ERROR" "Kural araması başarısız | IP: ${TARGET_IP} | Yanıt: ${RESPONSE}"
        return 1
    fi

    # Kural ID'sini çıkar
    local RULE_ID
    RULE_ID=$(echo "${RESPONSE}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [ -z "${RULE_ID}" ]; then
        log "WARN" "Silinecek kural bulunamadı | IP: ${TARGET_IP} (Zaten silinmiş olabilir)"
        return 0
    fi

    # Kuralı sil
    local DEL_RESPONSE
    DEL_RESPONSE=$(cf_api_call "DELETE" \
        "/zones/${CF_ZONE_ID}/firewall/access_rules/rules/${RULE_ID}" \
        "")

    if check_api_success "${DEL_RESPONSE}"; then
        log "INFO" "IP Access Rule silindi | IP: ${TARGET_IP} | Kural ID: ${RULE_ID}"
        return 0
    else
        log "ERROR" "IP Access Rule silinemedi | IP: ${TARGET_IP} | Kural ID: ${RULE_ID} | Yanıt: ${DEL_RESPONSE}"
        return 1
    fi
}

# =============================================================================
# WAF CUSTOM RULES IP LIST MODU (CF_MODE="list")
# =============================================================================

list_add() {
    local TARGET_IP="$1"

    if [ -z "${CF_LIST_ID}" ]; then
        log "ERROR" "CF_LIST_ID tanımlanmamış. IP List modu için gereklidir."
        return 1
    fi

    local DATA
    DATA=$(printf '[{"ip":"%s","comment":"OSSEC Ban %s"}]' "${TARGET_IP}" "$(date '+%Y-%m-%d')")

    local RESPONSE
    RESPONSE=$(cf_api_call "POST" \
        "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" \
        "${DATA}")

    if check_api_success "${RESPONSE}"; then
        log "INFO" "IP List'e eklendi | IP: ${TARGET_IP} | Liste ID: ${CF_LIST_ID}"
        return 0
    else
        log "ERROR" "IP List'e eklenemedi | IP: ${TARGET_IP} | Yanıt: ${RESPONSE}"
        return 1
    fi
}

list_delete() {
    local TARGET_IP="$1"

    if [ -z "${CF_LIST_ID}" ]; then
        log "ERROR" "CF_LIST_ID tanımlanmamış."
        return 1
    fi

    # Liste öğelerini çek ve hedef IP'nin item ID'sini bul
    local RESPONSE
    RESPONSE=$(cf_api_call "GET" \
        "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items?per_page=500" \
        "")

    if ! check_api_success "${RESPONSE}"; then
        log "ERROR" "Liste öğeleri alınamadı | Yanıt: ${RESPONSE}"
        return 1
    fi

    # jq varsa kullan, yoksa grep/sed ile çıkar
    local ITEM_ID=""
    if command -v jq >/dev/null 2>&1; then
        ITEM_ID=$(echo "${RESPONSE}" | jq -r --arg ip "${TARGET_IP}" \
            '.result[] | select(.ip == $ip) | .id' 2>/dev/null | head -1)
    else
        # Basit grep yöntemi (jq yoksa)
        ITEM_ID=$(echo "${RESPONSE}" | grep -B2 "\"${TARGET_IP}\"" | grep '"id"' | head -1 \
            | cut -d'"' -f4)
    fi

    if [ -z "${ITEM_ID}" ]; then
        log "WARN" "IP List'te silinecek öğe bulunamadı | IP: ${TARGET_IP}"
        return 0
    fi

    local DATA
    DATA=$(printf '{"items":[{"id":"%s"}]}' "${ITEM_ID}")

    local DEL_RESPONSE
    DEL_RESPONSE=$(cf_api_call "DELETE" \
        "/accounts/${CF_ACCOUNT_ID}/rules/lists/${CF_LIST_ID}/items" \
        "${DATA}")

    if check_api_success "${DEL_RESPONSE}"; then
        log "INFO" "IP List'ten silindi | IP: ${TARGET_IP} | Öğe ID: ${ITEM_ID}"
        return 0
    else
        log "ERROR" "IP List'ten silinemedi | IP: ${TARGET_IP} | Yanıt: ${DEL_RESPONSE}"
        return 1
    fi
}

# =============================================================================
# TEMEL DOĞRULAMALAR
# =============================================================================

# Log dizini yoksa oluştur
if [ ! -d "$(dirname "${ACTIVE_RESPONSE_LOG}")" ]; then
    mkdir -p "$(dirname "${ACTIVE_RESPONSE_LOG}")"
fi

# Ham çağrıyı logla (OSSEC formatı)
echo "$(date) $0 $1 $2 $3 $4 $5" >> "${ACTIVE_RESPONSE_LOG}"

# curl kontrolü
if ! command -v curl >/dev/null 2>&1; then
    log "ERROR" "curl bulunamadı. Lütfen curl'ü yükleyin: apt install curl / yum install curl"
    exit 1
fi

# Aksiyon parametresi kontrolü
if [ -z "${ACTION}" ]; then
    log "ERROR" "Aksiyon parametresi eksik. Kullanım: $0 <add|delete> <user> <ip>"
    exit 1
fi

# IP parametresi kontrolü
if [ -z "${IP}" ]; then
    log "ERROR" "IP adresi parametresi eksik. Kullanım: $0 <add|delete> <user> <ip>"
    exit 1
fi

# IP geçerlilik kontrolü
if ! validate_ip "${IP}"; then
    log "ERROR" "Geçersiz IP adresi formatı: ${IP}"
    exit 1
fi

# API Token kontrolü
if [ "${CF_API_TOKEN}" = "CLOUDFLARE_API_TOKEN_BURAYA" ] || [ -z "${CF_API_TOKEN}" ]; then
    log "ERROR" "CF_API_TOKEN yapılandırılmamış. Lütfen scripti düzenleyin."
    exit 1
fi

# Zone ID kontrolü
if [ "${CF_ZONE_ID}" = "ZONE_ID_BURAYA" ] || [ -z "${CF_ZONE_ID}" ]; then
    log "ERROR" "CF_ZONE_ID yapılandırılmamış. Lütfen scripti düzenleyin."
    exit 1
fi

# IPv6 normalizasyonu
NORMALIZED_IP=$(normalize_ipv6 "${IP}")

# =============================================================================
# ANA KONTROL AKIŞI
# =============================================================================

log "INFO" "Başlatıldı | Aksiyon: ${ACTION} | IP: ${NORMALIZED_IP} | Mod: ${CF_MODE}"

case "${ACTION}" in
    "add")
        if [ "${CF_MODE}" = "list" ]; then
            list_add "${NORMALIZED_IP}"
        else
            ip_access_add "${NORMALIZED_IP}"
        fi
        EXIT_CODE=$?
        ;;
    "delete")
        if [ "${CF_MODE}" = "list" ]; then
            list_delete "${NORMALIZED_IP}"
        else
            ip_access_delete "${NORMALIZED_IP}"
        fi
        EXIT_CODE=$?
        ;;
    *)
        log "ERROR" "Geçersiz aksiyon: '${ACTION}'. Beklenen: 'add' veya 'delete'"
        exit 1
        ;;
esac

if [ ${EXIT_CODE} -eq 0 ]; then
    log "INFO" "Tamamlandı | Aksiyon: ${ACTION} | IP: ${NORMALIZED_IP} | Durum: BAŞARILI"
else
    log "ERROR" "Tamamlandı | Aksiyon: ${ACTION} | IP: ${NORMALIZED_IP} | Durum: BAŞARISIZ"
fi

exit ${EXIT_CODE}
