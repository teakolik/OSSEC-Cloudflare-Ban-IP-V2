# Değişiklik Kaydı

## [2.0.0] - 2026-04-22

### Kırılan Değişiklikler
- `X-Auth-Email` / `X-Auth-Key` (Global API Key) kimlik doğrulama yöntemi **kaldırıldı**
- `/user/firewall/access_rules/rules` endpoint'i → `/zones/{zone_id}/firewall/access_rules/rules` olarak **değiştirildi**

### Eklenenler
- Bearer Token (`Authorization: Bearer`) kimlik doğrulama desteği
- WAF Custom Rules IP List modu (`CF_MODE=list`) — Pro+ planlara özel
- IPv6 tam desteği (CIDR normalizasyonu dahil)
- Retry mekanizması: API hataları ve rate limit durumunda otomatik 3 deneme
- Structured loglama: `[SEVERITY] timestamp | mesaj` formatı
- Zone-level IP Access Rules (hesap geneli yerine zone bazlı)
- `CF_ACTION` değişkeni ile `block`, `challenge`, `js_challenge`, `managed_challenge` seçenekleri
- API yanıt doğrulama (`"success":true` kontrolü)
- Yapılandırma eksikliği tespiti (boş token/zone ID için açık hata mesajları)
- `curl` varlık kontrolü
- `jq` opsiyonel bağımlılık (fallback grep/sed ile çalışır)

### Düzeltilenler
- Timeout sonrası delete işleminde kural bulunamazsa hata yerine uyarı loglanır
- IPv6 adresleri CIDR olmadan geldiğinde `/128` otomatik eklenir

## [1.0.0] - İlk Sürüm

- OSSEC Active Response ile Cloudflare IP Access Rules entegrasyonu
- add/delete aksiyon desteği
- Temel loglama
