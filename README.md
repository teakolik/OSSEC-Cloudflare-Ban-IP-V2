# OSSEC-Cloudflare-Ban-IP v2.0

OSSEC Active Response ile Cloudflare üzerinden zararlı IP adreslerini otomatik olarak engelleyen bash scripti.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Cloudflare API: v4](https://img.shields.io/badge/Cloudflare%20API-v4%20(Güncel)-orange)](https://developers.cloudflare.com/api/)
[![OSSEC Compatible](https://img.shields.io/badge/OSSEC-Uyumlu-green)](https://www.ossec.net/)

---

## v1 → v2 Ne Değişti?

| Özellik | v1 (Eski) | v2 (Yeni) |
|---|---|---|
| **Kimlik Doğrulama** | X-Auth-Email + X-Auth-Key (Global API Key) | Bearer Token (API Token) ✅ |
| **IP Access Rules API** | `/user/firewall/access_rules/rules` | `/zones/{zone_id}/firewall/access_rules/rules` ✅ |
| **WAF Custom Rules / IP List** | Yok | Destekleniyor (`CF_MODE=list`) ✅ |
| **IPv6 Desteği** | Yok | CIDR normalizasyonu ile tam destek ✅ |
| **Hata Yönetimi** | Yok | Retry mekanizması (3 deneme), HTTP kodu kontrolü ✅ |
| **Loglama** | Minimal | Structured log (timestamp + severity + mesaj) ✅ |
| **API Endpoint (Firewall Rules)** | `/user/firewall/access_rules/rules` (çalışıyor) | Zone-level endpoint (daha güvenli) ✅ |
| **jq Bağımlılığı** | Zorunlu | Opsiyonel (fallback ile çalışır) ✅ |
| **Yapılandırma Doğrulama** | Yok | Token/Zone ID boş bırakılınca açık hata ✅ |

> **Not:** Cloudflare **Firewall Rules API** (`/zones/{zone}/firewall/rules`) **2025-06-15** itibarıyla tamamen kaldırılmıştır.
> Bu script, hâlâ desteklenen **IP Access Rules API** ve önerilen **WAF Custom Rules IP List** yöntemlerini kullanmaktadır.

---

## Gereksinimler

- OSSEC HIDS (veya Wazuh)
- `curl` (sistemde kurulu olmalı)
- `jq` (opsiyonel — yoksa grep/sed fallback devreye girer)
- Cloudflare hesabı (ücretsiz plan yeterlidir, IP List modu için Pro+ gerekir)

---

## Kurulum

### 1. Cloudflare API Token Oluşturun

Eski yöntem olan Global API Key **güvensizdir** ve artık önerilmez. Bunun yerine scoped API Token kullanın:

1. [Cloudflare Dashboard](https://dash.cloudflare.com) → **My Profile** → **API Tokens** → **Create Token**
2. **Custom Token** seçin
3. Gerekli izinler:
   - `Zone > Firewall Services > Edit`
   - `Zone > Zone > Read`
   - (IP List modu için) `Account > Account Filter Lists > Edit`
4. Zone filtresini ilgili domain ile sınırlandırın
5. Token'ı güvenli bir yere kaydedin

### 2. Zone ID ve Account ID Bulun

- **Zone ID:** Dashboard → Domain seçin → Overview → sağ alt köşe
- **Account ID:** Dashboard → herhangi bir domain → Overview → sağ alt köşe

### 3. Scripti Kopyalayın

```bash
cp cloudflare_ban.sh /var/ossec/active-response/bin/cloudflare-ban.sh
chmod 750 /var/ossec/active-response/bin/cloudflare-ban.sh
chown root:ossec /var/ossec/active-response/bin/cloudflare-ban.sh
```

### 4. Scripti Yapılandırın

`cloudflare-ban.sh` dosyasını açın ve şu değerleri doldurun:

```bash
CF_API_TOKEN="eyJhbGciOiJSUzI1NiJ9..."   # Oluşturduğunuz API Token
CF_ZONE_ID="a6a6a6a6b1b1b2b2..."          # Zone ID
CF_ACCOUNT_ID="b1b2b3c4d5e6..."           # Account ID
CF_ACTION="block"                          # veya: challenge, js_challenge, managed_challenge
CF_MODE="ip_access"                        # veya: list (Pro+ plan gerektirir)
```

### 5. OSSEC Yapılandırması

`/var/ossec/etc/ossec.conf` dosyasına ekleyin:

```xml
<!-- Cloudflare Ban komutu tanımı -->
<command>
  <n>cloudflare-ban</n>
  <executable>cloudflare-ban.sh</executable>
  <timeout_allowed>yes</timeout_allowed>
  <expect>srcip</expect>
</command>

<!-- Active Response tetikleyici (önerilen kurallar) -->
<active-response>
  <command>cloudflare-ban</command>
  <location>server</location>
  <!-- Nginx/Apache 400-500 hataları, brute force, tarama tespiti -->
  <rules_id>31151,31152,31153,31154,31161,31164,31165,31104,31100,5710,5712,2502,2503</rules_id>
  <!-- 12 saat (43200 saniye) sonra engel otomatik kalkar -->
  <timeout>43200</timeout>
</active-response>
```

### 6. OSSEC'i Yeniden Başlatın

```bash
/var/ossec/bin/ossec-control restart
```

---

## Çalışma Modları

### Mod 1: IP Access Rules (`CF_MODE="ip_access"` — Varsayılan)

- **Tüm planlarda çalışır** (ücretsiz dahil)
- Hesap başına **50.000 kural** limiti
- Kural oluşturma ve silme otomatik
- Zone-level API endpoint kullanır

### Mod 2: WAF Custom Rules IP List (`CF_MODE="list"` — Önerilen Pro+)

- **Pro+ plan** gerektirir
- Tek bir IP listesine ekleme/çıkarma yapar
- Cloudflare'nin önerdiği modern yaklaşım
- Önce Dashboard'da `OSSEC-Blocked-IPs` adında bir IP List oluşturun:
  - **Manage Account** → **Configurations** → **Lists** → **Create new list**
  - Type: `IP`
  - List ID'yi alın ve `CF_LIST_ID` değişkenine yazın
- Liste referans alan bir WAF Custom Rule oluşturun:
  ```
  Expression: (ip.src in $ossec_blocked_ips)
  Action: Block
  ```

---

## Loglama

Script tüm işlemleri `/var/ossec/logs/active-responses.log` dosyasına yazar:

```
2026-04-22T14:35:01+0300 [INFO] cloudflare-ban.sh: Başlatıldı | Aksiyon: add | IP: 203.0.113.42 | Mod: ip_access
2026-04-22T14:35:02+0300 [INFO] cloudflare-ban.sh: IP Access Rule oluşturuldu | IP: 203.0.113.42 | Aksiyon: block | Kural ID: abc123def456
2026-04-22T14:35:02+0300 [INFO] cloudflare-ban.sh: Tamamlandı | Aksiyon: add | IP: 203.0.113.42 | Durum: BAŞARILI
```

---

## Manuel Test

Kurulumdan sonra scripti doğrudan test edebilirsiniz:

```bash
# Test: IP engelle
/var/ossec/active-response/bin/cloudflare-ban.sh add ossec 203.0.113.42

# Test: IP engelini kaldır
/var/ossec/active-response/bin/cloudflare-ban.sh delete ossec 203.0.113.42

# Test: IPv6
/var/ossec/active-response/bin/cloudflare-ban.sh add ossec 2001:db8::1
```

Logları kontrol edin:
```bash
tail -f /var/ossec/logs/active-responses.log
```

---

## Güvenlik Notları

- API Token'ı kesinlikle `cloudflare-ban.sh` dışında bir dosyada saklamayı tercih edin (örn. `/etc/cloudflare/credentials` — `chmod 600`)
- Global API Key kullanmayın — compromised olursa tüm hesabınız risk altına girer
- Token izinlerini **minimum gereksinim** prensibine göre sınırlandırın

---

## Desteklenen OSSEC Kural ID'leri (Önerilen)

| Kural ID | Açıklama |
|---|---|
| 31151-31154 | Nginx/Apache erişim hataları |
| 31161, 31164, 31165 | Web uygulama saldırıları |
| 31104, 31100 | HTTP tarama/saldırı |
| 5710, 5712 | SSH brute force |
| 2502, 2503 | Kullanıcı doğrulama başarısızlıkları |

---

## Lisans

MIT License — Hamza Şamlıoğlu / Privia Security

---

## Yazar

**Hamza Şamlıoğlu**  
Managing Partner, [Privia Security](https://priviasecurity.com)  
GitHub: [@teakolik](https://github.com/teakolik)  
LinkedIn: [linkedin.com/in/teakolik](https://www.linkedin.com/in/teakolik/)
