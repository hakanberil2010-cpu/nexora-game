

Proje

Nexora, Vercel + Supabase üzerinde çalışan tarayıcı tabanlı strateji oyunudur.

Ana repo:
hakanberil2010-cpu/nexora-game

En önemli çalışma kuralı

Mevcut çalışan sistemi koru.

Bir görev açıkça istemedikçe:

Dosyaları baştan yazma.

Gereksiz refactor yapma.

Biçimlendirme/format değişikliği yapma.

Çalışan özellikleri kaldırma.

UI öğelerini silme.

Mevcut API action isimlerini değiştirme.

Veritabanı şemasını gereksiz yere değiştirme.

Mümkün olan en küçük ve güvenli değişikliği yap.

Kesinlikle kaynak olarak kullanma

Aşağıdaki eski dosyaları hiçbir geliştirme için referans alma:

auth-part-00

auth-part-01

auth-part-02

auth-part-03

Bunlar eski sürümlerdir.

Her zaman repository içindeki güncel dosyaları temel al.

Ana dosyalar

Özellikle şu dosyalar birbirine bağlıdır:

api/auth.js

game.html

world.html

army.html

research.html

ranking.html

reports.html

alliance.html

trade.html

Supabase SQL şema/migration dosyaları

Bir dosyada değişiklik yapmadan önce ilgili backend/frontend bağlantılarını kontrol et.

Kod değişikliği yöntemi

Her görevde:

Önce mevcut dosyayı oku.

İstenen değişikliğin etkilediği fonksiyonları belirle.

Yalnızca gerekli bölümü değiştir.

Mevcut davranışları koru.

Değişiklik sonrası syntax kontrolü çalıştır.

Mümkünse ilgili akışı test et.

Sonuçta hangi dosyaların değiştiğini açıkça belirt.

JavaScript kontrolleri

Backend veya inline JavaScript değiştiğinde syntax kontrolü yap.

Örnek:

node --check api/auth.js

HTML içindeki script gerekiyorsa geçici dosyaya çıkarıp node --check ile kontrol et.

Syntax hatası olan kodu tamamlanmış sayma.

SQL kuralları

SQL migration yalnızca gerçekten gerekliyse oluştur.

Kurallar:

Mevcut tabloları gereksiz yere silme.

DROP TABLE kullanma; görev açıkça istemiyorsa yapma.

Veri kaybına neden olacak migration oluşturma.

Yeni alan gerekiyorsa mümkünse ADD COLUMN IF NOT EXISTS kullan.

Mevcut production verisini koru.

SQL gerekiyorsa ayrı migration dosyası oluştur.

UI koruma kuralları

Mevcut sayfalardaki navigasyonu koru.

Özellikle:

← Koloniye Dön butonlarını silme.

Var olan menü öğelerini kaldırma.

Yeni özellik eklerken mevcut sayfa düzenini mümkün olduğunca koru.

Mobil görünümü bozma.

Çalışan buton/event handler isimlerini sebepsiz değiştirme.

Yeni bir ana özellik ekleniyorsa gerekli menü bağlantısını da kontrol et.

Kaynak ve ekonomi sistemi

Mevcut kaynaklar:

metal

energy

water

crystal

Depolama kapasitesi kuralları backend tarafından belirlenir.

Kaynak ekleme/çıkarma işlemlerinde:

Negatif kaynak oluşmasına izin verme.

Kapasite sınırlarını koru.

Aynı işlemin iki kez uygulanmasını önle.

Para/kaynak transferlerinde idempotency düşün.

Bina sistemi

Mevcut bina yükseltme maliyet mantığı:

0 → 1 = base × 1

1 → 2 = base × 2

2 → 3 = base × 3

devamı aynı şekilde

Yani genel mantık:
cost = baseCost * (currentLevel + 1)

Mevcut maksimum seviyeleri ve ön koşulları koru.

Önemli ön koşullar:

Kristal Madeni: Merkez Bina 2

Kristal Deposu: Merkez Bina 2

Kışla: Merkez Bina 2

Konut: Merkez Bina 2

Sur: Merkez Bina 3

Savunma Kulesi: Merkez Bina 5 + Sur 2

Merkez Bina seviyesinin diğer binalar üzerindeki sınır mantığını bozma.

Ordu sistemi

Mevcut birlik türleri:

piyade

savunma

saldiri

okcu

tank

hava

Birlik üretimi:

kaynak maliyetlerini

nüfus kapasitesini

ordu kapasitesini

üretim süresini

Kışla bonusunu

korumalıdır.

Birlik seviyeleri gerçek savaş hesabına etki eder.

Savaş sistemi

Mevcut savaş/sefer sisteminde:

Birlik seçimi

Koordinat bazlı seyahat

Varışta savaş

Kayıplar

Yağma

Hayatta kalanların dönüşü

Savaş raporu

Savaş puanı

Sur ve Savunma Kulesi bonusu

Birim matchup avantajları

Birlik seviye etkileri

çalışmaktadır.

Bu akışlardan hiçbirini görev istemedikçe kaldırma veya sadeleştirme.

Özellikle:

Mission resolve işlemi çift çalışmamalı.

Survivor return çift kaynak/birlik eklememeli.

Idempotency korunmalı.

Yağma saldıranın depo kapasitesini aşmamalı.

Savaş raporlarındaki koordinatlar korunmalı.

Dünya sistemi

Mevcut sistem:

Oyuncu kolonileri

Koordinatlar

Hareket

Gerçek zamanlı seyahat

Bölgeler

Keşif

Dünya noktaları / siteler

içermektedir.

Koloni hareketi sırasında aktif askeri görev kontrolünü koru.

Araştırma sistemi

Araştırmalarda artan maliyet mantığını koru.

Genel:
cost = base * (level + 1)

Mevcut araştırma kuyruğu ve gerçek zamanlı sayaç sistemini bozma.

Sıralama sistemi

Mevcut skor sistemi şu unsurları kullanır:

koloni seviyesi

bina seviyeleri

ordu gücü

savaş puanı

galibiyet

araştırma seviyesi

Frontend tarafında:

NaN

undefined

null

gibi değerlerin kullanıcıya görünmesine izin verme.

İttifak sistemi

Mevcut özellikleri koru:

ittifak oluşturma

katılma

ayrılma

liderlik devri

liderin üye çıkarabilmesi

tek kalan lider ayrılırsa ittifakın silinmesi

Ticaret sistemi

Mevcut ticaret sistemi çalışmaktadır.

Özellikler:

teklif oluşturma

verilen kaynağı kilitleme

başka oyuncunun teklifi kabul etmesi

karşılıklı kaynak aktarımı

teklif iptali

kaynak iadesi

ticaret geçmişi

trade.html ana menüden erişilebilir olmalıdır.

Ticarette çift kabul, çift iade veya çift kaynak aktarımı oluşmamalı.

Gerçek zaman sistemi

Oyunun gerçek zamanlı mekanikleri mümkün olduğunca server time kullanır.

İstemci saati tek başına güvenilir kabul edilmemelidir.

Şunları koru:

üretim

inşaat

araştırma

birlik üretimi

sefer

dönüş

sürelerinin gerçek zamanlı çalışması.

Güvenlik

API tarafında:

Kullanıcı kimliğini request body içinden güvenilir kabul etme.

Token/auth doğrulamasını koru.

Başka oyuncının verisini değiştiren işlemlerde sahiplik kontrolü yap.

Kaynak ve birlik miktarlarında negatif/sıfır/NaN değerleri doğrula.

Client tarafından gönderilen savaş gücü, maliyet, kaynak miktarı gibi hesaplanabilir değerleri doğrudan kabul etme.

Kritik hesapları backend tarafında yap.

Kod stili

Mevcut dosyanın stilini koru.

Dosya minified veya tek satırsa, görev bunu gerektirmiyorsa komple prettify etme.
Dosya düzenliyse mevcut formatı takip et.

Amaç:
minimum diff + maksimum güvenlik.

Git çalışma şekli

Mümkünse her bağımsız özellik için ayrı commit oluştur.

Commit mesajları kısa ve açıklayıcı olsun.

Örnek:

Add trade link to colony menu

Fix battle survivor idempotency

Add colony back button to trade page

Bir görev birden fazla dosyayı etkiliyorsa hepsini aynı mantıksal commit içinde tut.

İş bitirme kriteri

Bir görev ancak şu şartlarda tamamlanmış sayılır:

İstenen özellik uygulanmış.

Eski özellikler korunmuş.

Syntax kontrolü geçmiş.

Gerekli API/frontend bağlantıları kontrol edilmiş.

Gerekliyse SQL migration hazırlanmış.

Değişen dosyalar net biçimde belirtilmiş.

Bilinen risk veya test edilmemiş durum varsa açıkça yazılmış.

Öncelik

Bir talimat çakışırsa şu sırayı uygula:

Kullanıcının son açık isteği

Bu AGENTS.md kuralları

Mevcut çalışan Nexora davranışı
Minimum değişiklik prensibi
