# server-setup

Bộ script dựng một VPS Debian/Ubuntu để chạy web app bằng Docker, theo mô hình:

```
                 Internet
                    │
            ┌───────▼────────┐
            │   Cloudflare   │  DNS proxied (orange cloud), SSL mode: Full (strict)
            └───────┬────────┘
                    │ :80 / :443  (chỉ 2 port này mở ra internet)
            ┌───────▼────────┐
            │    Traefik     │  TLS bằng Cloudflare Origin Certificate
            │  (container)   │  route theo Host() → container trên traefik-proxy-network
            └───┬───────┬────┘
                │       │
           ┌────▼──┐ ┌──▼────┐
           │ app A │ │ app B │   không publish port nào ra host
           └───────┘ └───────┘

   Bạn (laptop) ──Tailscale──▶ SSH :22, DB, dashboard, ...   (không bao giờ đi qua internet)
```

Nguyên tắc: **internet chỉ thấy Traefik**, mọi thứ quản trị đi qua **Tailscale**, app không bao giờ publish port.

## Cấu trúc thư mục

```
server-setup/
├── 1-harden.sh                 # chạy 1 lần, as root: user + SSH key + Tailscale + sshd + ufw
├── 2-install-docker.sh         # chạy 1 lần, sudo: Docker CE + daemon.json + shared network
└── 3-traefik/                  # copy lên server thành ~/traefik
    ├── docker-compose.yml      # socket-proxy (cổng read-only cho docker.sock) + traefik
    ├── traefik.yml             # static config: entrypoints, providers, log
    ├── add-cert.sh             # paste origin cert → validate → sinh dynamic/tls.yml
    ├── dynamic/
    │   ├── tls.yml             # GENERATED bởi add-cert.sh — không sửa tay
    │   └── middlewares.yml     # cloudflare-only, secure-headers, compress (toàn cục); rate-limit (opt-in)
    ├── certs/                  # <domain>.pem / <domain>.key (gitignored)
    └── examples/whoami/        # mẫu compose cho một app đứng sau Traefik
└── 4-tunnel/                   # TÙY CHỌN, chỉ cho máy không có IP công khai (laptop dev, máy ở nhà)
    ├── docker-compose.yml      # cloudflared → https://traefik:443 trên traefik-proxy-network
    ├── config.yml              # một luật catch-all, giống nhau mọi máy
    └── tunnel.sh               # zone / init / route / status
```

## Chuẩn bị trước khi chạy

- [ ] VPS Debian 12+ / Ubuntu 22.04+ **mới cài**, có đăng nhập root (password hoặc key).
- [ ] Trên laptop đã có SSH key ed25519: `ls ~/.ssh/*.pub` (chưa có thì `ssh-keygen -t ed25519`).
- [ ] Tài khoản Tailscale, laptop đã cài và đăng nhập Tailscale.
- [ ] Domain đã trỏ nameserver về Cloudflare.
- [ ] Biết cách mở **console của nhà cung cấp VPS** (đường cứu hộ nếu khoá nhầm SSH).

## Thứ tự cài đặt

### Bước 0 — Copy script lên server

```bash
scp -r 1-harden.sh 2-install-docker.sh root@<PUBLIC_IP>:/root/
```

### Bước 1 — Harden (as root, chạy đúng 1 lần)

```bash
ssh root@<PUBLIC_IP>
apt-get install -y tmux && tmux new -s harden   # khuyến nghị: sống sót khi rớt mạng
bash 1-harden.sh
```

Script sẽ hỏi: tên user mới, tên file key trên laptop, mật khẩu user (đây là mật khẩu
**cứu hộ qua console VPS**, đặt mạnh và lưu lại), và public key.

Script dừng **3 lần** để bạn tự test từ laptop ở terminal khác. Không gõ `OK` nếu test chưa đạt.
Giữ session root mở cho đến khi thấy `DONE`.

| CHECK | Phải đạt |
|---|---|
| 1 | SSH bằng key qua IP Tailscale vào được, `sudo whoami` ra `root` |
| 2 | Sau khi khoá sshd vẫn SSH vào được |
| 3 | SSH qua IP Tailscale OK **và** SSH qua IP public bị timeout/refused |

Sau khi `DONE` (script cũng in nhắc dòng đầu):

1. **Vào Tailscale admin console → Machines → server → Disable key expiry.** Mặc định node key
   hết hạn sau 180 ngày; hết hạn là mất SSH vì port 22 đã đóng với internet. Việc này chỉ làm
   được trên dashboard Tailscale, script không tự làm được.
2. Nếu script báo kernel mới: `sudo reboot`, rồi SSH lại qua Tailscale để chắc máy lên bình thường.
3. Thêm vào `~/.ssh/config` trên laptop (script in sẵn block này):

```
Host myserver
    HostName <TAILSCALE_IP>
    User khanh
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

Những gì harden đã làm: cập nhật OS + bật `unattended-upgrades`; tạo user sudo; cài Tailscale;
sshd chỉ cho key, không root, không password, chỉ user này (`/etc/ssh/sshd_config.d/00-hardening.conf`,
bản gốc backup tại `/etc/ssh/sshd_config.bak.*`); ufw deny all, mở 80/443 ra internet, mọi thứ còn lại
chỉ qua `tailscale0`; khoá tài khoản root.

### Bước 2 — Docker (as user thường, qua sudo)

```bash
ssh myserver
sudo bash 2-install-docker.sh
exit   # đăng xuất rồi vào lại để nhóm docker có hiệu lực
```

Những gì script đã làm và **vì sao**:

- Cài Docker CE từ repo chính thức (xoá `docker.io` của distro nếu có).
- `/etc/docker/daemon.json`:
  - `"ip": "127.0.0.1"` — Docker ghi iptables riêng và **bỏ qua ufw**, nên `-p 5432:5432` bình thường
    sẽ phơi DB ra internet. Với setting này, publish port mặc định chỉ bind localhost.
  - log rotation 10m × 3 — container nói nhiều không làm đầy đĩa.
  - `live-restore` — container không chết khi dockerd restart.
- Thêm user vào nhóm `docker`, tạo network `traefik-proxy-network` dùng chung.

Quy ước publish port từ giờ:

```yaml
ports:
  - "0.0.0.0:443:443"          # công khai — CHỈ Traefik được làm thế này
  - "100.x.y.z:5432:5432"      # chỉ qua Tailscale (IP Tailscale của server)
  # app bình thường: KHÔNG có ports:, Traefik nối qua traefik-proxy-network
```

### Bước 3 — Traefik

```bash
# trên laptop
scp -r 3-traefik myserver:~/traefik

# trên server
cd ~/traefik
bash add-cert.sh          # paste Origin Certificate + Private Key từ Cloudflare
docker compose up -d
docker compose logs -f traefik   # phải ổn định, không có "level":"error"
```

`add-cert.sh` lấy cert ở: Cloudflare → domain → **SSL/TLS → Origin Server → Create Certificate**,
RSA 2048, hostnames `example.com` + `*.example.com`, 15 năm. Script kiểm tra key khớp cert, SAN đủ
2 tên, ghi `certs/`, sinh lại `dynamic/tls.yml`, và nếu Traefik đang chạy thì handshake thật để
xác nhận cert mới đã được phục vụ. Chạy lại bao nhiêu lần, bao nhiêu domain cũng được.
**Không sửa tay `dynamic/tls.yml`**, script sẽ ghi đè.

Trên Cloudflare cho mỗi domain: **SSL/TLS → Overview → Full (strict)**. Mọi record trỏ về server
phải **Proxied** và là record **A** (container bind IPv4). Record không proxied sẽ bị Traefik trả
403 vì middleware `cloudflare-only` chỉ nhận kết nối từ dải IP Cloudflare hoặc Tailscale.

`docker compose up -d` chạy 2 container:

| Container | Vai trò |
|---|---|
| `socket-proxy` | Giữ `docker.sock`, chỉ cho phép vài endpoint GET (containers, networks, events). Nằm trên network `internal`, app không với tới. |
| `traefik` | Proxy. Không mount socket, hỏi `socket-proxy` qua `tcp://socket-proxy:2375`. Bị chiếm cũng chỉ đọc được label container. |

### Bước 4 — Deploy app đầu tiên

```bash
mkdir -p ~/apps/whoami && cp ~/traefik/examples/whoami/docker-compose.yml ~/apps/whoami/
# sửa Host(`whoami.example.com`) thành domain thật
cd ~/apps/whoami && docker compose up -d
curl -I https://whoami.example.com      # sau khi tạo record A proxied
```

Mỗi app chỉ cần đúng 3 thứ: join `traefik-proxy-network`, label `traefik.enable=true`,
rule `Host()` trên entrypoint `websecure`, và khai báo port container bằng
`traefik.http.services.<name>.loadbalancer.server.port`. **Không có `ports:`.**

TLS, redirect 80→443, `cloudflare-only`, `secure-headers`, `compress` đã gắn sẵn ở entrypoint
`websecure` cho mọi app. Opt-in thêm cho endpoint login/API:

```yaml
traefik.http.routers.myapp.middlewares: "rate-limit@file"
```

`rate-limit` đếm theo header `CF-Connecting-IP`. Header này đáng tin vì `cloudflare-only` đã chặn mọi
kết nối không đến từ Cloudflare, nên không ai tự đặt được nó.

### Máy không có IP công khai — `4-tunnel` (tùy chọn)

Laptop dev hay máy ở nhà không có `<PUBLIC_IP>:443` cho Cloudflare trỏ vào. `4-tunnel` chạy cloudflared trong
container: nó gọi ra Cloudflare và giao mọi request cho Traefik qua `traefik-proxy-network`. Từ Traefik trở vào
giống hệt server. Bước 1 (harden) thường không áp dụng cho laptop; bước 2–3 vẫn cần (Docker, network, Traefik).

```bash
cd 4-tunnel
bash tunnel.sh zone example.com      # mỗi zone một lần → zones/<zone>.pem
bash tunnel.sh init                  # mỗi máy một lần (hay: init ~/.cloudflared/<id>.json để dùng lại tunnel có sẵn)
docker compose up -d
bash tunnel.sh route app.example.com # mỗi hostname một lần: CNAME proxied → tunnel này
```

Chi tiết: [4-tunnel/README.md](4-tunnel/README.md).

## Vận hành

| Việc | Lệnh |
|---|---|
| Vào server | `ssh myserver` |
| Log Traefik | `cd ~/traefik && docker compose logs -f traefik` |
| Thêm domain mới | `cd ~/traefik && bash add-cert.sh` |
| Nâng Traefik | sửa tag trong `docker-compose.yml`, đọc release notes, `docker compose pull && docker compose up -d` |
| Update OS / Docker / Tailscale | `sudo apt update && sudo apt upgrade` (unattended-upgrades **chỉ** cài bản security của distro, không đụng repo Docker/Tailscale) |
| Cần reboot không | `ls /var/run/reboot-required` |
| Thêm user SSH | thêm vào `AllowUsers` trong `/etc/ssh/sshd_config.d/00-hardening.conf`, `sudo systemctl reload ssh` |
| Xem rule firewall | `sudo ufw status verbose` |
| Dọn image cũ | `docker system prune -af --volumes` (cẩn thận volume) |
| Xem router Traefik | tạm thêm `api: {dashboard: true, insecure: true}` vào `traefik.yml`, publish `"<TAILSCALE_IP>:8080:8080"`, xong thì bỏ |

### Tắt `cloudflare-only` (nếu sau này cần)

Middleware này gắn ở entrypoint trong [3-traefik/traefik.yml](3-traefik/traefik.yml), không nằm trong app
nào, nên chỉ cần sửa một chỗ.

**Tắt toàn cục, vẫn dùng Cloudflare phía trước** (ví dụ muốn test thẳng IP, hoặc có host không proxied):

1. Trong `traefik.yml`, xoá dòng `- cloudflare-only@file` khỏi `entryPoints.websecure.http.middlewares`.
2. `traefik.yml` là static config, không hot-reload: `cd ~/traefik && docker compose restart traefik`.
3. `rate-limit` đang đếm theo header `CF-Connecting-IP`. Khi không còn chặn, header này giả được,
   nên trong `dynamic/middlewares.yml` đổi `sourceCriterion` sang IP kết nối thật:

   ```yaml
   sourceCriterion:
     ipStrategy:
       depth: 0          # dùng địa chỉ TCP peer
   ```

   Nếu vẫn chỉ nhận traffic từ Cloudflare thì `depth: 0` sẽ thấy IP Cloudflare, tức rate-limit gần như vô dụng.
   Đây là lý do nên giữ `cloudflare-only` khi còn dùng Cloudflare.
4. Muốn chặn theo từng app thay vì toàn cục: thêm label
   `traefik.http.routers.<name>.middlewares: "cloudflare-only@file"` cho app đó. Middleware vẫn còn
   trong `middlewares.yml`, chỉ không áp tự động nữa.

**Bỏ Cloudflare hoàn toàn** (trỏ DNS thẳng về server): làm 3 bước trên, và thêm:

- Origin cert chỉ được Cloudflare tin, browser sẽ báo lỗi. Phải chuyển sang Let's Encrypt:
  thêm `certificatesResolvers` (HTTP challenge trên entrypoint `web`) vào `traefik.yml`, mount một volume
  ghi được cho `acme.json`, bỏ `tls: {}` thành `tls: {certResolver: <tên>}` trên `websecure`, và không
  chạy `add-cert.sh` nữa.
- Xoá `forwardedHeaders.trustedIPs` trên `websecure` (không còn ai hợp lệ để gửi X-Forwarded-For).
- Access log đang keep header `CF-Connecting-IP` / `CF-Ray`, không hại nhưng vô nghĩa, có thể bỏ.
- Mất WAF, bot protection, cache của Cloudflare. Cân nhắc fail2ban hoặc rate-limit chặt hơn ở Traefik.

## Troubleshooting

- **Mất SSH hoàn toàn**: vào console nhà cung cấp VPS, đăng nhập bằng user + mật khẩu đã đặt ở bước 1,
  `sudo -i`. Kiểm tra `tailscale status` (key expired?), `sudo ufw status`.
- **Cloudflare 526**: hostname không nằm trong SAN của origin cert, hoặc chưa chạy `add-cert.sh`
  cho domain đó. Test cert thật đang được phục vụ:
  `echo | openssl s_client -connect 127.0.0.1:443 -servername x.example.com 2>/dev/null | openssl x509 -noout -subject -issuer`
- **Cloudflare 502 / Traefik 404**: container chưa join `traefik-proxy-network`, thiếu `traefik.enable`,
  sai `server.port`, hoặc Host() không khớp. Xem `docker compose logs traefik`.
- **403 khi gọi domain**: record DNS chưa Proxied (xám thay vì cam), hoặc bạn gọi thẳng IP public.
  Gọi qua Tailscale thì được vì dải `100.64.0.0/10` nằm trong allowlist.
- **Traefik không thấy app nào, log có `403` hoặc `connection refused` tới `socket-proxy`**:
  `docker compose ps` xem `socket-proxy` có chạy; endpoint Docker API bị thiếu thì bật thêm biến
  tương ứng (`INFO`, `NETWORKS`...) trong `docker-compose.yml`.
- **Đổi tls.yml mà không có tác dụng**: `docker compose restart traefik` (file watcher hiếm khi bỏ lỡ).
- **Container bind IP Tailscale không lên sau reboot**: tailscale0 chưa có IP khi Docker start,
  `restart: unless-stopped` sẽ tự thử lại; nếu không, `docker compose up -d` lại.
- **Port lỡ bị phơi ra internet**: `sudo ss -tlnp | grep -v 127.0.0.1` — chỉ nên thấy :80, :443
  (Traefik) và các địa chỉ 100.x.y.z.

## Kết quả soát (10/2026)

Bộ này đã đúng phần lớn best practice. 4 điểm ưu tiên cao tìm thấy khi soát **đã được sửa**:

| Điểm | Đã làm |
|---|---|
| Tailscale key expiry không được nhắc | `1-harden.sh` in nhắc ở `DONE`; README bước 1. Phần tắt thật phải làm trên dashboard Tailscale. |
| Traefik cầm `docker.sock` (= root host) | Thêm `socket-proxy` read-only, Traefik không mount socket nữa. |
| `cloudflare-only` chỉ opt-in, origin gọi thẳng được | Gắn ở entrypoint `websecure`; thêm dải Tailscale vào allowlist. |
| `stsPreload: true` | Bỏ. |
| Tài liệu lệch với script (README trong `3-traefik`, tên file trong header script, nhắc k3s) | Viết lại cả hai README, sửa header. |

Còn lại là các điểm nên làm dần, xếp theo ưu tiên.

**Ưu tiên trung bình**

1. **Chưa phải git repo**, không có `.gitignore` ở root (có `.DS_Store` lạc vào). Nên `git init`
   và ignore `.DS_Store`, `*.pem`, `*.key`.
2. **IPv6**: `0.0.0.0:443:443` chỉ bind IPv4. Nếu tạo record AAAA, Cloudflare sẽ nối origin qua
   IPv6 và bị refused. Hoặc chỉ dùng record A, hoặc thêm `"[::]:80:80"` / `"[::]:443:443"`.
3. **Cập nhật**: unattended-upgrades chỉ lo security của Debian/Ubuntu. Docker, Tailscale, image
   Traefik cần `apt upgrade` / `compose pull` định kỳ. Kernel update không tự reboot
   (`Unattended-Upgrade::Automatic-Reboot` mặc định false) — chấp nhận được nhưng phải nhớ.
4. **`unattended-upgrades` dựa vào `dpkg-reconfigure`** để sinh `20auto-upgrades`; chắc chắn hơn
   là ghi thẳng file đó với `APT::Periodic::Update-Package-Lists "1"` và
   `APT::Periodic::Unattended-Upgrade "1"`.

**Ưu tiên thấp / nice-to-have**

5. Danh sách IP Cloudflare bị lặp ở `traefik.yml` và `middlewares.yml`; khi Cloudflare đổi range
    phải sửa 2 chỗ.
6. `examples/whoami` dùng tag `:latest`; app thật nên pin version.
7. Container Traefik có thể thêm `read_only: true` (Traefik không ghi gì); `daemon.json` có thể
    thêm `"no-new-privileges": true` cho toàn bộ container.
8. Nhóm `docker` tương đương root — chấp nhận được cho server một người dùng, nhưng cần biết.
9. Chưa có backup volume. Tối thiểu: `docker run --rm -v <vol>:/data -v $PWD:/backup alpine tar czf /backup/<vol>.tgz /data`
    theo cron, đẩy đi nơi khác.

Những gì đã **đúng** và nên giữ nguyên: thứ tự Tailscale → khoá sshd → ufw với 3 lần tự test;
sshd config qua `sshd_config.d/00-*` có backup và rollback; `AuthenticationMethods publickey`;
`ufw allow in on tailscale0`; daemon.json `ip: 127.0.0.1`; `exposedByDefault: false`;
`no-new-privileges` + healthcheck cho Traefik; không bật dashboard; `add-cert.sh` validate key/SAN
trong temp dir trước khi ghi và handshake xác nhận sau khi reload; `.gitignore` cho `*.pem`/`*.key`.

Lưu ý khi áp dụng trên server **đang chạy** bản cũ: `cd ~/traefik && docker compose up -d` là đủ
(compose tạo `socket-proxy` và recreate `traefik`); kiểm tra `docker compose logs traefik` thấy
router của các app vẫn được nạp, và `curl -I https://<app>` qua Cloudflare vẫn 200.
