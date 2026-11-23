# Changelog

[English](CHANGELOG.md) · Tiếng Việt

Mọi thay đổi đáng chú ý của ColimaX được ghi trong file này. Bản tiếng Anh [CHANGELOG.md](CHANGELOG.md) là bản gốc; release notes được trích từ bản đó.

Định dạng dựa trên [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), và project tuân theo [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Các ID `G…` / `R…` tham chiếu tới [docs/AUDIT.vi.md](docs/AUDIT.vi.md).

## [Unreleased]

### Added

- Trợ lý cài đặt: chuyển từ OrbStack / Docker Desktop sang Colima (G27). Phát hiện runtime khác và, sau khi xác nhận từng bước, trỏ context của docker CLI sang profile đang chọn (có Chuyển lại), thay credential helper `desktop` của Docker Desktop bằng `osxkeychain`, dời các link hỏng trong `cli-plugins` và thoát app kia. Với `/var/run/docker.sock` chỉ hiện lệnh `sudo` thay vì tự chạy. Tự mở khi khởi động nếu runtime khác vẫn đang giữ docker CLI.

## [1.0.0-beta.1] - 2026-11-22

Bản pre-release đầu tiên của **1.0.0**. Ký ad-hoc, chưa notarize bởi Apple (xem [docs/RELEASE.vi.md](docs/RELEASE.vi.md) §3.6). Mục 1.0.0 chính thức sẽ lặp lại danh sách này cùng các bản sửa lỗi trong giai đoạn beta.

### Thêm mới

#### Cài đặt

- Trợ lý cài đặt: kiểm tra Homebrew, `colima`, `docker` CLI và plugin compose; cài công cụ còn thiếu bằng `brew install` sau khi xác nhận (có log và nút huỷ trong sheet); cấu hình `cliPluginsExtraDirs` cho plugin compose cài qua Homebrew, có backup docker config; khởi động profile Colima đầu tiên. Tự mở khi thiếu công cụ (có thể tắt) và mở được từ menu app.

#### Runtime

- Trạng thái VM và start / stop / restart; chọn profile từ toolbar và menu bar.
- Tạo / xoá profile; cấu hình CPU, RAM, disk, kiến trúc, container runtime, VM type (vz / qemu / krunkit), mount type (virtiofs / sshfs / 9p), Rosetta, Kubernetes (k3s) và nested virtualization; cảnh báo trước và hỏi xác nhận khi phải tạo lại VM.
- Dashboard: mức dùng CPU / RAM / disk thực tế bên trong VM, Docker info, dung lượng lưu trữ.
- Endpoint Docker lấy từ `colima status --json` (`docker_socket`), nếu không có thì dùng socket mặc định của profile (G2).
- Cập nhật realtime qua Docker `/events` và theo dõi thư mục Colima bằng kqueue, có poll dự phòng mỗi 30 s (C11).

#### Containers

- Danh sách có lọc; start / stop / restart / pause / unpause / xoá; icon health.
- Chi tiết container: restart count, restart policy, OOMKilled, exit code, health và probe gần nhất, giới hạn memory / CPU / PIDs, network / IP, mount, biến môi trường với giá trị nhạy cảm được che (G6).
- Logs stream và export ra file (G7); inspect JSON; exec; mở shell trong Terminal.

#### Compose

- Phát hiện project qua label; thêm project từ thư mục cùng file compose, override và `.env`, không tự khởi động.
- up / down / start / stop / restart / pull; logs; validate; xem config hợp nhất; restart và rebuild từng service (G15).

#### Images, Volumes, Networks

- Images: pull có tiến trình theo từng layer, xoá, prune, inspect, cột kiến trúc và cảnh báo image không phải arm64 (G11).
- Volumes: tạo, xoá, prune, inspect.
- Networks: tạo (driver, subnet, gateway, internal), xoá, prune, inspect, connect / disconnect container (G14).

#### Backup

- Backup volume ra `.tar` kèm manifest `<file>.manifest.json` (kích thước, SHA-256); "Verify Backup"; restore xác minh manifest và cấu trúc tar trước khi ghi (G8).
- Backup database dạng logic qua Docker exec API: MySQL / MariaDB, PostgreSQL, Redis / Valkey / KeyDB; kiểm tra exit code và dấu hiệu dump hoàn tất (G9).

#### Diagnostics và bảo mật

- Màn Diagnostics: colima / docker CLI, endpoint, `/_ping`, Docker context, lệch cấu hình, VZ / virtiofs / Rosetta, gợi ý tài nguyên, dung lượng disk VM (G10).
- Security audit chỉ đọc: privileged mode, capability nguy hiểm, mount `docker.sock`, host network / pid / ipc, `unconfined`, port bind `0.0.0.0`, tên biến giống secret, quyền socket (G12).
- Phát hiện port trùng và port bị process trên host chiếm (G16).

#### Monitoring và dung lượng

- Monitoring CPU / RAM / network / block I/O theo container (C8).
- Màn Storage: volume không dùng, image dangling / không dùng, container đã dừng, build cache; dọn dẹp có xác nhận (G13).

#### Backup nâng cao

- Restore database dump vào container đang chạy: MySQL / MariaDB / PostgreSQL qua client của chính database, Redis / Valkey bằng cách thay file RDB; kiểm tra manifest, loại dump và độ hoàn chỉnh của dump trước khi đụng tới Docker; xác nhận bằng cách gõ tên container (G21).
- Backup PostgreSQL dùng `pg_dumpall --clean --if-exists` để restore được vào cluster có sẵn.
- Lịch backup định kỳ cho volume và database, giữ N bản gần nhất (chỉ xoá file do lịch tạo và có manifest khớp), chạy bù khi mở app, thông báo khi lỗi; màn Backups (G19).

#### Monitoring

- Lấy mẫu tài nguyên nền mỗi phút, lịch sử 3 ngày, cảnh báo khi CPU / RAM container hoặc disk VM vượt ngưỡng liên tục; sheet History & Alerts; cấu hình trong Preferences (G20).

#### Công cụ

- Quét lỗ hổng image bằng Trivy hoặc Docker Scout đã cài (G24).
- Snapshot Elasticsearch / OpenSearch: tạo, liệt kê, xoá, restore (copy hoặc ghi đè), export repository (G25).
- Màn Topology: đồ thị network ↔ container và `depends_on` của Compose (G22).
- Màn Local Domains: reverse proxy Caddy cho `*.localhost`, HTTPS qua CA nội bộ, nút tin cậy CA tuỳ chọn (G23).

#### App

- Cửa sổ chính với sidebar bốn nhóm (Overview / Docker / Tools / Settings), icon menu bar, cửa sổ Settings.
- Phím tắt ⌘1…⌘9 theo thứ tự sidebar, menu "Go" (G17); ⌘R làm mới; ⇧⌘R chạy lại Diagnostics.
- Preferences: giao diện Light / Dark / System, icon Dock, mở khi đăng nhập, tự khởi động VM, thông báo.
- Huỷ thao tác chạy lâu, với trạng thái "Cancelled" riêng (G4).

#### Kỹ thuật

- I/O blocking (socket, hash file, dò port) chạy trên GCD queue riêng thay vì cooperative thread pool; timeout và huỷ cho process và request Docker (G1).
- File backup được ghi ra file tạm trong cùng thư mục rồi rename; lỗi ghi được báo và không để lại file dở dang (G3).
- Log viewer append tăng dần; formatter dùng chung; `Shell.which` tìm theo `PATH` (G5).
- Từng loại dữ liệu Docker tải lại độc lập; transcript Exec có giới hạn kích thước; container hỗ trợ backup còn sót được tự động dọn.
- Bộ XCTest: unit test và integration test có điều kiện; `scripts/run-tests.sh`, `scripts/dev-build.sh`, `scripts/build-app.sh` (T1).

### Bảo mật

- Không có App Sandbox; Hardened Runtime không có entitlement.
- Mọi lệnh trên host chạy với mảng tham số, không bao giờ qua shell; tên profile / volume / network / project compose / service / image được kiểm tra; path và query Docker API được percent-encode.
- File backup, manifest và log export được tạo với quyền 0600.
- Credential database chỉ dùng bên trong container và truyền qua biến môi trường (`MYSQL_PWD`, `REDISCLI_AUTH`), không bao giờ qua argv hay đi qua app.
- Secret trong biến môi trường được che trong UI; security audit chỉ liệt kê tên biến, không bao giờ liệt kê giá trị.
- Thao tác destructive cần hộp thoại xác nhận.
