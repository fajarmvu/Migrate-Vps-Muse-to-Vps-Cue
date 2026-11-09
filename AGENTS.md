# AGENTS.md — Instruksi untuk agent yang mengeksekusi migrasi

Repositori ini berisi playbook migrasi VM/VPS via Tailscale. Ada dua cara pakai:

- **Mode manusia (README.md):** perintah copy-paste untuk dua bot (Bot MUSE di
  mesin sumber, Bot CUE di mesin tujuan), dengan manusia sebagai perantara.
- **Mode agent (berkas ini):** kamu mengeksekusi langsung dari mesin sumber.
  Ikuti urutan fase di bawah; jangan melompat.

## 0. Prasyarat (wajib lolos sebelum mulai)

1. Salin `config.env.example` menjadi `config.env` dan isi SEMUA nilai asli
   (nama/IP Tailscale kedua mesin, user SSH tujuan, path kunci SSH).
2. Jalankan `./scripts/check-prereqs.sh` — semua cek harus `[OK]`.
   Jangan lanjut jika ada `[GAGAL]`.

## 1. Aturan keras (tidak boleh dilanggar)

- **Rahasia tidak pernah ditampilkan**: password, token, API key, private key
  SSH, atau isi berkas rahasia tidak boleh dicetak ke chat, log, atau commit.
  Public key SSH boleh ditampilkan.
- **Tidak ada dual-active**: bot polling, scheduler, worker tunggal, dan tunnel
  produksi hanya boleh hidup di SATU mesin dalam satu waktu.
- **Izin manusia wajib** sebelum: menghentikan layanan produksi, reboot,
  mengubah firewall, menghapus data, dan memulai cutover.
- **Jangan hapus mesin sumber** selama masa pengujian. Rollback harus selalu
  tersedia sampai migrasi dinyatakan final.

## 2. Urutan eksekusi (peta ke fase README.md)

| Tahap | Aksi | Bukti selesai |
|---|---|---|
| Audit sumber | Inventaris service, port, data, cron, tunnel (baca-saja) | Manifest tertulis |
| Tailscale | Kedua node online, ping dua arah | `tailscale status` + ping OK |
| SSH | Kunci migrasi dibuat; public key terpasang di tujuan | SSH batch-mode OK |
| Siapkan tujuan | Direktori, runtime, unit systemd (jangan start) | `systemd-analyze verify` OK |
| Salinan awal | rsync dry-run dulu, lalu salin; DB via dump/snapshot | checksum cocok |
| Cutover | Hentikan sumber → final sync → start tujuan berurutan | `CUE_AKTIF_SEMENTARA` |
| Verifikasi | Endpoint, data, log, akses publik; reboot bila disetujui | `CUE_SIAP_PAKAI` |
| Finalisasi | Sumber pasif, autostart lama dimatikan, rollback siap | `MUSE_PASIF_SIAP_ROLLBACK` |

Detail tiap fase ada di README.md. Jika tujuan gagal di fase mana pun,
jalankan prosedur rollback (tujuan berhenti dulu, sumber hidup setelahnya).

## 3. Template yang tersedia

- `scripts/gen-migration-key.sh` — buat kunci SSH ed25519 khusus migrasi.
- `scripts/vps-ssh.sh` — wrapper SSH via Tailscale ke mesin tujuan.
- `scripts/proxy-ssh-helper.py` — helper koneksi SSH (lihat README skrip).
- `scripts/gateway-watch-vps.sh` — watchdog gateway (cek service aktif +
  koneksi Telegram :443; restart bila perlu; exit 0/1/2/3).
- `scripts/vps-rsync.sh` — wrapper rsync via jalur SSH yang sama.
- `scripts/check-prereqs.sh` — validasi prasyarat (wajib lolos).
- `systemd/` — template unit `app-gateway.service`, `model-router.service`,
  `tunnel@.service`. Ganti placeholder `<USER>`, `<APP_DIR>`, `<PORT>`,
  `<EXEC_START>` sebelum dipakai.
- `systemd/vps-ssh-persistent.service` — koneksi SSH persisten ke mesin tujuan
  (auto-reconnect via `Restart=always` + `ServerAliveInterval`). Pelengkap
  monitoring berkala, bukan pengganti.

## 4. Laporan status

Gunakan token status yang sama seperti README agar konsisten:
`CUTOVER_SUMBER_SIAP` / `CUTOVER_GAGAL`, `CUE_AKTIF_SEMENTARA` /
`ROLLBACK_DIPERLUKAN`, `CUE_SIAP_PAKAI`, `MUSE_PASIF_SIAP_ROLLBACK` /
`MUSE_AKTIF_KEMBALI`, `CUE_PASIF_ROLLBACK`.

## 5. Troubleshooting (pelajaran dari lapangan, 2026-10-08)

### Tailscale SSH merebut port 22
- **Gejala:** SSH dijawab `SSH-2.0-Tailscale`, muncul
  `# Tailscale SSH requires an additional check` + URL login. Kunci SSH biasa
  tidak bisa dipakai.
- **Penyebab:** Tailscale SSH aktif di mesin tujuan dan mengalahkan OpenSSH.
- **Perbaikan (di mesin tujuan, akses langsung):**
  `tailscale set --ssh=false && systemctl enable --now ssh`,
  lalu pastikan `systemctl is-active ssh` = `active`.
- **Catatan:** untuk automation (bot/monitoring), OpenSSH lebih tepat daripada
  Tailscale SSH — Tailscale SSH butuh identitas interaktif, tidak kenal kunci
  otomasi. Jaringan Tailscale sendiri sudah privat, jadi OpenSSH di IP
  Tailscale sudah cukup aman.

### Jaringan VPS flapping (putus-nyambung)
- **Gejala:** SSH timeout + tunnel publik 502 bersamaan, tapi `uptime` mesin
  tidak reset (tidak reboot).
- **Diagnosis:** `uptime` hanya reset saat reboot — outage jaringan tidak
  mengubahnya. Koroborasi dengan jalur independen: (1) tunnel Cloudflare 502
  = tidak ada tunnel client yang terhubung; (2) log aplikasi di VPS menunjukkan
  VPS itu sendiri tidak bisa mencapai internet (mis. timeout ke api.telegram.org).
  Jika dua-duanya gagal bersamaan, masalahnya jaringan VPS, bukan probe.
- **Perbaikan:** butuh akses console/operator VPS — tidak bisa dari jarak jauh
  saat jaringan mati (chicken-and-egg). Setelah pulih, restart service yang
  sempat degradasi (mis. gateway) dan verifikasi ulang.

### Jebakan systemd pada unit SSH
- `%` di dalam unit file adalah specifier systemd — tulis `%%h %%p` agar ssh
  menerima `%h %p` untuk ProxyCommand.
- Di container tanpa user bus (`systemctl --user` gagal "No medium found"),
  pakai **system service**, bukan user service; `login linger` tidak relevan.
- Service di `/etc/systemd/system/` bisa hilang saat VM diganti total —
  monitoring berkala (cron) tetap diperlukan sebagai pengaman.

### Kredensial egress proxy muter (rotate)
- **Gejala:** SSH via proxy gagal dengan `Connection closed by UNKNOWN port
  65535`; pola berulang kira-kira tiap 1 jam; VPS sendiri hidup (bot Telegram
  masih bisa dihubungi) dan Tailscale masih me-list node-nya.
- **Penyebab:** kredensial proxy egress dirotasi berkala. File env statis
  (mis. `HTTPS_PROXY=...` yang ditulis sekali) menjadi basi; setiap reconnect
  SSH gagal auth sehingga relay menutup CONNECT tanpa respon.
- **Perbaikan:** jangan andalkan file statis — refresh kredensial dari
  environment live di setiap cek berkala; kalau isi file berubah dan service
  SSH persistent sedang crash-loop, restart service agar memakai kredensial
  baru. Pola outage 2026-10-08: 08:24, 10:49, 16:06, 17:59, 20:59–21:14.

### Format EnvironmentFile systemd (bug nyata)
- File env untuk `EnvironmentFile=` di unit systemd **wajib** format
  `VAR=nilai` per baris. Menulis URL mentah (tanpa prefix `HTTPS_PROXY=`)
  membuat service crash-loop tiap 15 detik (`KeyError('HTTPS_PROXY')`) —
  padahal probe SSH dari luar tetap terlihat "UP" karena memakai env shell,
  bukan env file. Bug semacam ini lolos dari monitoring luar.
- **Perbaikan:** selalu tulis dengan format `VAR=value`; tambahkan fallback
  di helper proxy agar membaca env file langsung dan menerima kedua format.

### Monitoring token-free (Telethon + systemd, 2026-10-09)
- Cron agent AI tiap 5 menit = 288 run/hari walau sehat — boros token.
  Hook pernah dicoba tapi jalur notifikasi gagal total (zero notification).
- **Solusi:** systemd timer tiap 2 menit jalanin script bash
  (`token-free-monitor/tg-link-monitor.sh`) — probe SSH + state di file,
  nol token AI. Lihat `token-free-monitor/README.md`.
- Wake-up ke bot platform via **Telethon** (MTProto, akun user langsung) —
  tidak perlu browser/AI. Sesi diautentikasi sekali via `auth.py`
  (butuh `api_id`/`api_hash` dari my.telegram.org + kode login).
- MTProto TCP langsung sering diblokir egress — script otomatis route via
  `$HTTPS_PROXY` (butuh `python-socks`).
- File rahasia (`tg-api.conf`, `gladis.session`) chmod 600, **jangan di-commit**.

### VM diganti runtime (link mati total)
- **Gejala:** semua koneksi mati mendadak dalam satu waktu; `uptime` VM kecil
  (baru boot); file di `/etc/systemd/system/` hilang.
- **Penyebab:** runtime mengganti VM secara berkala; `/etc/` tidak persisten,
  hanya home directory yang selamat.
- **Perbaikan:** simpan template unit di direktori persisten (mis. workspace);
  setiap run monitoring cek keberadaan unit file dan bangun ulang service dari
  template bila hilang (`daemon-reload` + `enable --now`). Ini self-healing,
  tidak perlu alert ke manusia.

### "Sleep" vs outage — cara membedakan
- Kalau VPS masih bisa dihubungi lewat jalur independen (mis. bot Telegram
  dibalas) tapi SSH via Tailscale mati → yang tidur hanya jalur Tailscale/
  relay, bukan VPS-nya. Traffic outbound dari VPS (mis. membalas chat)
  sering "membangunkan" jalur tersebut kembali — korelasi ini mudah dikira
  kausalitas, jadi uji dengan kontrol: biarkan auto-recovery jalan tanpa
  intervensi manual, lihat apakah pulih sendiri.

### Wake theory — TERBUKTI (2026-10-08)
- **Observasi:** chat ke bot Telegram yang jalan di VPS memulihkan SSH yang
  mati — berulang kali, termasuk saat relay 3130 mati total (~23:38 WIB).
- **Mekanisme:** pesan masuk → bot di VPS membalas → traffic outbound dari
  VPS lewat Tailscale → jalur/relay "bangun" → SSH nyambung lagi (<1 menit).
- **Kontrol negatif:** kirim pesan via Bot API dari sisi client SAJA tidak
  memulihkan — karena tidak menghasilkan traffic dari sisi VPS. Harus ada
  traffic yang keluar DARI VPS.
- **Solusi permanen (auto-wake):** systemd timer di VPS tiap 2 menit
  menjalankan script keepwarm (TCP SYN + tailscale ping ke IP tailnet VM)
  — jalur tidak pernah idle cukup lama untuk tidur. Tidak perlu chat manual
  lagi. Lihat `tailnet-keepwarm.sh` + `tailnet-keepwarm.timer`.

### Relay 3130 mati total (bukan kredensial)
- **Gejala:** `Connection closed by UNKNOWN port 65535` TAPI proxy HTTPS
  biasa (port 3128) normal — curl via proxy return 401 (bukti kredensial
  valid). Test langsung ke port 3130: koneksi diterima tapi respons kosong.
- **Artinya:** relay tailnet di sisi runtime mati/tidak respons — bukan
  masalah kredensial, bukan masalah VPS. Tidak bisa diperbaiki dari sisi
  client selain menunggu atau memicu traffic dari sisi VPS (wake).

### Host VPS tidur (sleep) — root cause outage berulang (2026-10-09)
- **Gejala:** SSH via Tailscale mati berkala (pedot beberapa menit/jam, pulih
  sendiri atau setelah ada aktivitas manual di sisi operator), padahal semua
  service di VPS auto-start normal setiap kali host bangun.
- **Diagnosis:** log Tailscale di VPS mencatat 10x
  `slept ... probably wake from sleep` dalam 24 jam (info dari operator
  platform via asisten AI mereka). Komputer host (shared/sandbox) tidur saat
  idle — selama tidur, SSH/Tailscale tidak terjangkau walau service akan
  auto-start begitu host bangun.
- **Batasan platform:** sleep idle TIDAK bisa dimatikan dari dalam VM;
  keepalive/tmux di dalam VM hanya membantu setelah VM bangun. Opsi
  always-on resmi hanya lewat feedback ke operator platform.
- **Implikasi:** sebagian outage "relay menutup CONNECT" yang berulang
  sebelumnya adalah gejala VPS tidur, bukan masalah relay/kredensial di sisi
  client. Auto-wake (keepwarm timer) dan keepalive hanya bisa pulih SETELAH
  host bangun — tidak bisa mencegah tidurnya.
- **Solusi permanen:** host yang tidak pernah tidur — VPS beneran atau STB
  Armbian di rumah (tidak ada istilah "sleep").

### Wake via bot Telegram platform (2026-10-09)
- **Situasi:** satu-satunya jalur ke operator platform adalah bot Telegram
  resmi mereka (`@manus_ai_agent_bot`) — tidak ada API/console lain yang
  bisa dijangkau saat link mati.
- **Alur otomatis (di keepalive, maks 1x per outage agar tidak spam):**
  link terdeteksi DOWN → kirim pesan ke bot via Telegram Web (sesi login akun
  user, persisten di profil browser) minta cek/bangunkan VM "Muse" →
  tunggu ~60 detik → probe SSH ulang; kalau UP, anggap pulih.
- **Contoh pesan (Inggris, sopan):** "Hi, my sandbox VM named 'Muse' on the
  Cue platform seems to be asleep — SSH over Tailscale is unreachable and
  Tailscale logs showed 'slept ... probably wake from sleep'. Could you
  please check/wake it? Thank you."
- **Terverifikasi 2026-10-09:** pesan test dibalas bot
  ("I received your test message. Thanks!") — alur kirim→balas jalan penuh.
- **Catatan:** login Telegram Web butuh bantuan user sekali (scan QR / kode
  verifikasi); sesi bertahan di profil browser setelahnya.
