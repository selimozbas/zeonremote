<p align="center">
  <img src="docs/images/icon.png" width="128" alt="ZeonVNC ikonu">
</p>

<h1 align="center">ZeonVNC</h1>

<p align="center">
  macOS için hızlı ve native bir <b>VNC</b>, <b>SSH</b>, <b>Telnet</b> ve <b>SFTP</b> istemcisi —
  uzak masaüstü, terminal ve dosya aktarımı tek uygulamada.
</p>

<p align="center">
  <a href="https://github.com/selimozbas/zeonvnc/releases/latest"><b>İndir</b></a> ·
  <a href="docs/USER_GUIDE.md">Kullanım kılavuzu (EN)</a> ·
  <a href="docs/BUILDING.md">Derleme (EN)</a> ·
  <a href="README.md">English</a>
</p>

---

ZeonVNC, macOS için AppKit ve Metal ile geliştirildi. Standart VNC sunucularına
(UltraVNC, TightVNC, VNC şifresiyle RealVNC, Raspberry Pi'deki WayVNC, x11vnc ve
diğerleri) bağlanır, SSH ve Telnet terminali açar ve iki panelli pencerede SFTP ile
dosya aktarır — test cihazlarıyla dolu laboratuvar ve ofisler için idealdir.

## Özellikler

**Uzak masaüstü (VNC)**
- IOSurface framebuffer'dan doğrudan Metal çizim (kopyasız), sRGB renk, küçültmede
  mipmap ile okunaklı metin
- Ölçekleme: pencereye sığdır, %100, Retina 1:1, yay, yakınlaştırma ve pinch-zoom
- Encoding: Tight (JPEG), ZRLE, Hextile, Raw, CopyRect ve **donanım hızlandırmalı
  H.264** (VideoToolbox; örn. Raspberry Pi'nin donanım kodlayıcısı)
- Kalite profilleri veya özel encoding / JPEG kalitesi / sıkıştırma / renk derinliği
- Güvenlik: VNC şifresi, Plain, VeNCrypt TLS / X509, RSA-AES (RA2), DH, MSLogonII;
  "sadece şifreli bağlantılar" modu
- Otomatik yeniden bağlanma, ters bağlantı (5500 portu), uzak ekranı pencereye göre
  boyutlandırma
- Klavye: ⌘ kısayolları dahil tüm tuşlar uzağa gider; ⌘ tuşu Ctrl, Windows veya Alt
  olabilir; yerel kısayollar ⌃⌥⌘
- Ctrl-Alt-Del ve Windows kısayolları, panoyu tuş vuruşu olarak yazdırma, çift yönlü
  pano, ekran görüntüsü, canlı istatistik, native sekme ve tam ekran

**SSH ve Telnet terminali**
- xterm-256color terminal: vim, htop, tmux, nano, renkler ve fare çalışır
- SSH: ssh-agent, `~/.ssh` anahtarları veya şifre; Telnet: terminal türü ve pencere
  boyutu anlaşması
- VNC oturumundan tek tıkla aynı cihaza SSH terminali veya dosya aktarım penceresi

**Dosya aktarımı (SFTP)**
- İki panel: solda bu Mac, sağda uzak cihaz; iki yöne sürükle-bırak, Yükle / İndir
  düğmeleri, çift tıklama ile karşıya kopyalama
- Aynı isimli dosya varsa sorar: **Değiştir, İkisini de Tut, Atla, Durdur**
  (isteğe bağlı olarak tümüne uygula); klasörler birleştirilir
- VNC oturumunda uzak ekrana bırakılan dosyalar uzak masaüstüne yüklenir

**Bağlantılar ve kimlik bilgileri**
- Arama, gruplar ve son bağlantılarla adres defteri; JSON içe/dışa aktarma, `.vnc`
  bağlantı dosyalarını içe aktarma; `vnc://` adresleri
- Hızlı Bağlan: `host`, `host::port`, `ssh kullanıcı@host -p 2222`, `telnet host 23`
- Şifreler macOS Keychain'de saklanır — ya da hiç saklanmaz: Ayarlar'da kapalıysa
  her bağlantıda sorulur
- **DHCP ağları için cihaz başına güven**: şifreler, TLS sertifikaları ve SSH host
  anahtarları IP adresine değil cihaza (yerel ağda MAC adresine) bağlıdır. Aynı IP'yi
  başka bir cihaz alırsa kayıtlı şifre gönderilmez ve ne değiştiği söylenir.

## Kurulum

[Sürümler sayfasından](https://github.com/selimozbas/zeonvnc/releases/latest)
`ZeonVNC-0.3.dmg` dosyasını indirin, açın ve ZeonVNC'yi Uygulamalar klasörüne
sürükleyin.

**Gereksinim:** Apple silicon işlemcili Mac, macOS 13 Ventura veya üstü.

Sürüm henüz Apple tarafından notarize edilmediği için ilk açılışta bir adım daha
gerekir: Uygulamalar'da ZeonVNC'ye sağ tıklayın → **Aç** → **Aç**, ya da:

```bash
xattr -dr com.apple.quarantine /Applications/ZeonVNC.app
```

Yerel ağdaki bir cihaza ilk bağlanışta macOS, ZeonVNC'nin yerel ağa erişip
erişemeyeceğini sorar — izin verin.

## Lisans

ZeonVNC özgür yazılımdır: **GNU Genel Kamu Lisansı, sürüm 2 veya (tercihinize göre)
daha sonraki bir sürüm** — bkz. [LICENSE](LICENSE). İkili (DMG) sürümler ek
kütüphaneler içerir ve GPL-3.0-or-later koşullarıyla dağıtılır; bkz.
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
