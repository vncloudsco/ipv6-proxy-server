# IPv6 Proxy Server

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Tạo máy chủ proxy IPv6 backconnect chỉ với **một script** trên Linux. Mỗi proxy dùng một địa chỉ IPv6 ngẫu nhiên trong subnet của bạn — phù hợp crawl, parse, traffic arbitrage (Google, Facebook, YouTube, Instagram và nhiều dịch vụ khác hỗ trợ IPv6).

---

## Yêu cầu

- Máy chủ Linux (Debian/Ubuntu khuyến nghị), chạy với quyền **root**
- Subnet IPv6 đầy đủ đã được nhà cung cấp route về server (ví dụ `/64`, `/48`)
- Kết nối IPv6 ra ngoài hoạt động bình thường

> Nhiều VPS (DigitalOcean, …) chỉ cấp **một** địa chỉ IPv6, không phải cả subnet — script sẽ không hoạt động đúng trong trường hợp đó.

---

## Cài đặt nhanh

```bash
wget https://raw.githubusercontent.com/vncloudsco/ipv6-proxy-server/master/ipv6-proxy-server.sh
chmod +x ipv6-proxy-server.sh
sudo ./ipv6-proxy-server.sh -s 64 -c 100
```

Mặc định mỗi proxy có **user/password ngẫu nhiên 8 ký tự** (chữ và số, không ký tự đặc biệt).

### Các chế độ xác thực

| Chế độ | Cách dùng | Mô tả |
|--------|-----------|--------|
| Random (mặc định) | Không cần flag, hoặc `--random` | Mỗi proxy một cặp user/pass riêng |
| User/pass cố định | `-u user -p pass` | Tất cả proxy dùng chung một tài khoản |
| Không auth | `--no-auth` | Không yêu cầu đăng nhập |

```bash
# Random auth (mặc định)
sudo ./ipv6-proxy-server.sh -s 64 -c 100 -t http -r 10

# User/pass cố định
sudo ./ipv6-proxy-server.sh -s 64 -c 100 -u myuser -p mypass -t http

# Không xác thực
sudo ./ipv6-proxy-server.sh -s 64 -c 100 --no-auth
```

### Cấu hình lại / gỡ cài đặt

Script đã cài thì chạy lại lệnh mới là đủ — instance cũ tắt, cấu hình mới áp dụng ngay, không cần cài lại:

```bash
sudo ./ipv6-proxy-server.sh -s 64 -c 20 -u user2 -p pass2 -t socks5 -r 2
```

Gỡ hoàn toàn (dừng proxy, xóa cấu hình, cron, firewall, metadata):

```bash
sudo ./ipv6-proxy-server.sh --uninstall
```

Xem thông tin proxy đang chạy:

```bash
sudo ./ipv6-proxy-server.sh --info
```

---

## File xuất proxy

Sau khi khởi động, danh sách proxy được ghi ra **4 định dạng** (mặc định trong `~/proxyserver/`):

| File | Định dạng | Ví dụ | Dùng để |
|------|-----------|--------|---------|
| `.list` | `host:port:user:password` | `180.113.14.28:30000:a1b2c3d4:e5f6g7h8` | Tương thích cũ |
| `.txt` | `protocol://user:password@host:port` | `http://a1b2c3d4:e5f6g7h8@180.113.14.28:30000` | Import phần mềm |
| `.json` | Mảng object JSON | `{"protocol":"http","host":"...","port":30000,...}` | API / script |
| `.csv` | Cột: `protocol,host,port,username,password,url` | — | Excel / bảng tính |

Không auth thì `.list` là `host:port`, `.txt` là `protocol://host:port`, cột user/pass trong CSV/JSON để trống.

Đường dẫn mặc định:

```
~/proxyserver/backconnect_proxies.list
~/proxyserver/backconnect_proxies.txt
~/proxyserver/backconnect_proxies.json
~/proxyserver/backconnect_proxies.csv
```

Đổi base path bằng `-f` (nếu truyền đuôi `.list`/`.txt`/`.json`/`.csv` thì phần đuôi sẽ bị bỏ để lấy base).

---

## Tham số dòng lệnh

### Cơ bản

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| `-s`, `--subnet` | `64` | Prefix IPv6 subnet đã cấp cho server (chia hết cho 4: `48`, `56`, `64`, …). Xem [subnet IPv6](https://docs.netgate.com/pfsense/en/latest/network/ipv6/subnets.html) |
| `-c`, `--proxy-count` | *(bắt buộc)* | Số lượng proxy cần tạo |
| `-t`, `--proxies-type` | `http` | Loại proxy: `http` hoặc `socks5` |
| `--start-port` | `30000` | Port IPv4 bắt đầu. Ví dụ 100 proxy từ port `30000` → `IP:30000` … `IP:30099` |

### Xác thực

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| `--random` | **bật** | Mỗi proxy một user/pass ngẫu nhiên 8 ký tự (`A–Z`, `a–z`, `0–9`) |
| `-u`, `--username` | — | User dùng chung cho mọi proxy (tắt random) |
| `-p`, `--password` | — | Password dùng chung (phải dùng cùng `-u`) |
| `--no-auth` | tắt | Tắt xác thực proxy |

Không dùng chung `--no-auth` với `-u`/`-p` hoặc `--random`. Không dùng `-u`/`-p` cùng `--random`.

### Xoay IP (rotation)

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| `-r`, `--rotating-interval` | `0` | Chu kỳ đổi toàn bộ IP IPv6 ra ngoài (phút, `0`–`59`). `0` = tắt. Mỗi lần xoay sẽ restart proxy vài giây |
| `--rotate-every-request` | tắt | Mỗi request dùng IP IPv6 khác trong subnet. Không hỗ trợ mọi VPS; nếu không cấu hình được script sẽ báo lỗi (`-r` bị bỏ qua) |

### Giới hạn truy cập

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| `--allowed-hosts` | — | Chỉ cho phép các host này (cách nhau bởi dấu phẩy, không khoảng trắng). Host khác bị chặn. Ví dụ: `"google.com,*.google.com,fb.com"` |
| `--denied-hosts` | — | Chặn các host này; host khác được phép. **Không** dùng cùng lúc với `--allowed-hosts` |
| `-l`, `--localhost` | tắt | Chỉ lắng nghe `127.0.0.1` (proxy không public ra ngoài) |

### Nâng cao (chỉ khi tự detect sai)

| Tham số | Mặc định | Mô tả |
|---------|----------|--------|
| `-b`, `--backconnect-ip` | tự detect | IPv4 backconnect của server |
| `-i`, `--interface` | tự detect | Tên card mạng gắn subnet IPv6 |
| `-m`, `--ipv6-mask` | tự detect | Phần cố định của địa chỉ IPv6 (không có `:` cuối). Dùng khi địa chỉ có `::` khiến script parse sai. Ví dụ IP `2a03:6f01:5::1da6` với `/64` → `--ipv6-mask 2a03:6f01:5:0`. Với subnet không chia hết cho 16, truyền **đủ** block cuối (ví dụ `/56` → `2a01:7e01:f403:a000`, không rút thành `…:a0`) |
| `-f`, `--backconnect-proxies-file` | `~/proxyserver/backconnect_proxies` | Base path cho file xuất (`.list`, `.txt`, `.json`, `.csv`) |

### Quản lý

| Tham số | Mô tả |
|---------|--------|
| `--info` | In thông tin proxy đang chạy (số lượng, auth, rotation, đường dẫn file, …) |
| `--uninstall` | Gỡ proxy server và dọn cấu hình |
| `-h`, `--help` | Hiện hướng dẫn sử dụng |

---

## File & thư mục quan trọng

| Đường dẫn | Nội dung |
|-----------|----------|
| `~/proxyserver/` | Thư mục cấu hình chính |
| `~/proxyserver/backconnect_proxies.*` | Danh sách proxy đã xuất |
| `~/proxyserver/3proxy/3proxy.cfg` | Cấu hình 3proxy (IPv6 gateway, port, auth) |
| `~/proxyserver/ipv6.list` | Danh sách IPv6 đang gắn (khi không xoay mỗi request) |
| `~/proxyserver/running_server.info` | Thông tin server (dùng với `--info`) |
| `/var/tmp/ipv6-proxy-server-logs.log` | Log lần chạy gần nhất |

---

## Xử lý sự cố

Proxy không hoạt động — lần lượt kiểm tra:

1. Đọc log: `/var/tmp/ipv6-proxy-server-logs.log`. Lỗi subnet/cấp phát → hỏi nhà cung cấp VPS.
2. Chạy `sudo ./ipv6-proxy-server.sh --info`.
3. Kiểm tra file xuất (`.list` / `.txt`) có đúng IP:port và credential không.
4. Mở `~/proxyserver/3proxy/3proxy.cfg`, xác nhận địa chỉ IPv6 `-e…` hợp lệ.
5. Thử kết nối trực tiếp bằng một IPv6 trong cấu hình:
   ```bash
   curl --interface <ipv6-address> https://ipv6.ip.sb
   ```
   Nếu lệnh này OK mà proxy vẫn lỗi → mở [issue](https://github.com/Temporalitas/ipv6-proxy-server/issues).
6. Site đích phải có bản ghi DNS **AAAA**. Không có AAAA thì không vào được qua proxy IPv6.
7. Xác nhận VPS đã cấp **cả subnet** IPv6, không chỉ một địa chỉ.

Câu hỏi khác: [GitHub Issues](https://github.com/Temporalitas/ipv6-proxy-server/issues).

---

## Giấy phép

[MIT](https://opensource.org/licenses/MIT)
