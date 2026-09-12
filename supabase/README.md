# Nexora Supabase şema / migration notları

Bu klasör Codex'in mevcut Supabase yapısını tahmin etmek yerine eldeki gerçek migration geçmişini okuyabilmesi için hazırlanmıştır.

## Önemli

Bu dosyalar geçmişte Nexora için hazırlanmış SQL dosyalarıdır.
Bunlar tek başına çalışan veritabanının tam ve kesin `schema.sql` export'u değildir.

Özellikle `players`, `cities`, `buildings`, `research`, `units`, `alliances`,
`alliance_members`, `battle_reports` gibi bazı temel tabloların ilk CREATE TABLE
tanımları bu pakette eksik olabilir; çünkü ilk Supabase kurulumu ayrı yapılmıştır.

Bu nedenle Codex:
- mevcut veriyi silmemeli,
- DROP TABLE kullanmamalı,
- mevcut kolonları varsayarak yıkıcı migration üretmemeli,
- önce `api/auth.js` kullanımını ve buradaki migration geçmişini karşılaştırmalıdır.

## Migration sırası

1. `001_legacy_final_system.sql`
   Eski temel genişletmeler, gerçek zamanlı kuyruklar, askeri görevler ve unit_levels.

2. `002_v2_core.sql`
   V2 kapasite, nüfus, üretim kuyruğu, askeri görev alanları ve güncel birlik seviye verileri.

3. `003_phase2_battle_world.sql`
   Savaş puanı, winner alanları, ilk world_sites yapısı ve keşif altyapısı.

4. `004_phase4_trade.sql`
   Ticaret teklifleri, işlem geçmişi ve atomik ticaret fonksiyonları.

## World Phase 3 taslağı

`reference/world_phase3_draft_NEEDS_RECONCILIATION.sql` dosyası daha gelişmiş dünya/keşif
yapısı için hazırlanmış bir taslaktır.

DİKKAT:
Phase 2'de `world_sites` daha önce farklı kolonlarla oluşturulmuş olabilir.
Bu taslak `CREATE TABLE IF NOT EXISTS` kullandığı için mevcut tabloya yeni kolonları otomatik
eklemez. Bu nedenle bu dosya doğrudan production'a uygulanmamalıdır.

Önce gerçek Supabase şeması kontrol edilmeli ve gerekirse güvenli bir ALTER migration
hazırlanmalıdır.

## Gerçek production şemasını alma

`inspect-current-schema.sql` Supabase SQL Editor'da çalıştırılabilir.
Çıktı mevcut tabloları, kolonları ve önemli şema bilgisini görmeye yardımcı olur.

Mümkün olduğunda gerçek production şeması ayrıca export edilip:
`supabase/schema.sql`
olarak repoya eklenmelidir.

Bu işlem yapılana kadar migration dosyaları "referans + tarihçe" olarak kullanılmalıdır.
