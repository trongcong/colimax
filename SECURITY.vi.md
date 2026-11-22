# Bảo mật

[English](SECURITY.md) · Tiếng Việt

Tài liệu này mô tả mô hình bảo mật, các biện pháp đã triển khai trong code 1.0.0 và các giới hạn đã biết. Các biện pháp đều có unit test. Backup / restore volume, truyền file nguyên tử (atomic) và dump / restore database (MySQL, MariaDB, PostgreSQL, Redis) có integration test chạy với VM Colima thật; hộp thoại xác nhận và che secret có UI test (xem [docs/TESTING.vi.md](docs/TESTING.vi.md)).

## Mô hình và threat model

ColimaX chạy với quyền của người dùng đang đăng nhập, điều khiển Colima CLI và Docker Engine qua unix socket. Ai điều khiển được Docker socket thì có quyền tương đương root bên trong VM; ColimaX không mở rộng quyền đó, nhưng cũng không thu hẹp được nó.

| Mối đe doạ | Biện pháp giảm thiểu |
|---|---|
| Shell injection trên host qua tên profile, service, container hoặc đường dẫn | `Process` với mảng tham số, không bao giờ dùng `/bin/sh`; tên được kiểm tra bằng regular expression; tham số `colima start` lấy từ danh sách cố định |
| Path / query injection trong request Docker API | Mọi path segment và giá trị query đều được percent-encode |
| Lộ secret qua UI, kết quả audit, log hoặc file | Giá trị được che trong UI; audit chỉ ghi tên biến; credential database chỉ dùng bên trong container; file ghi với quyền 0600 |
| Mất hoặc hỏng dữ liệu khi backup / restore | Ghi ra file tạm rồi rename; manifest SHA-256; xác minh trước khi restore |
| Vô tình kích hoạt thao tác destructive | Hộp thoại xác nhận |
| Chèn code vào app đang chạy | Hardened Runtime, không có entitlement nới lỏng |

Ngoài phạm vi: bảo vệ trước malware đã chạy dưới cùng user, bảo mật bên trong container hoặc image của người dùng, và bảo mật của chính Colima / Docker.

## Sandbox, Hardened Runtime, quyền

- **Không bật App Sandbox.** App phải chạy `colima` / `limactl` / `docker` cài qua Homebrew và kết nối tới socket trong `~/.colima`; sandbox chỉ cho phép việc này thông qua entitlement temporary-exception (xem ADR-1 trong [docs/ARCHITECTURE.vi.md](docs/ARCHITECTURE.vi.md)).
- **Bật Hardened Runtime** (`codesign --options runtime` trong `scripts/build-app.sh`) và **không có entitlement nào**: không `disable-library-validation`, không `allow-jit`, không `get-task-allow`.
- **Không cần root**, và không cài privileged helper nào.
- Phạm vi truy cập: binary trên PATH (đường dẫn Homebrew trước, sau đó PATH của process), `$COLIMA_HOME` (mặc định `~/.colima`), `~/.docker` (chỉ đọc, cho Diagnostics), file người dùng chọn qua panel Save / Open, và thư mục tạm.

## Chạy lệnh

- Mọi lệnh trên host chạy qua `Process` với **mảng tham số** (`Shell.run`, `Shell.stream`, `ProcessExecution`). `Shell.which` từ chối tên có chứa `/`.
- Tham số `colima start` lấy từ danh sách cố định hoặc là số (`RuntimeConfig.startArguments`).
- `colima ssh` của Dashboard chạy một script hằng đọc `/proc` và `df` (`ColimaService.vmUsage`).
- `sh -c` **chỉ chạy bên trong container**:
  - Script dump database (`DatabaseEngine.script`) là hằng và không nội suy input (có unit test).
  - Tab Exec chạy lệnh người dùng gõ, trong container họ đã chọn. Đây là tính năng, không phải đường injection vào host.
  - Script restore database (`DatabaseRestore.script`, `redisConfigScript`) là hằng; file dump được đặt vào `/tmp/colimax-restore.dump` qua archive API và bị xoá bởi `trap` khi script kết thúc.
  - Request snapshot Elasticsearch (`ElasticsearchSnapshot.requestScript`): method / path / body được truyền dưới dạng **argv** (`sh -c <constant script> sh <method> <path> <body>`) và không nội suy vào script. `curl -k` chỉ dùng cho `localhost:9200` bên trong chính container đó.
- Quét lỗ hổng chạy `trivy` / `docker scout` **do người dùng tự cài** (app không bao giờ tải chúng), với tham số dạng mảng và image reference đã được kiểm tra (`VulnerabilityScanner.isValidReference`).
- Tin cậy CA của proxy chạy `security add-trusted-cert -r trustRoot -p ssl -k <login keychain> <file>` chỉ khi người dùng bấm và xác nhận; macOS tự hỏi mật khẩu, app không bao giờ thấy mật khẩu.
- Nút Open Terminal (`TerminalLauncher`, `Sources/ColimaX/Core/SystemIntegration.swift`) tạo file `.command` quyền 0700 trong thư mục tạm; container ID phải toàn ký tự hex, và đường dẫn được đặt trong dấu nháy đơn.

## Kiểm tra input và encoding

| Input | Quy tắc | Code |
|---|---|---|
| Tên profile | `^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$` | `ColimaService.isValidProfileName` |
| Tên volume | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` | `NameSheet` (`Features/Volumes/VolumesView.swift`) |
| Tên network | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$` | `CreateNetworkSheet` (`Features/Networks/NetworksView.swift`) |
| Subnet / gateway | `^[0-9a-fA-F:.]+/[0-9]{1,3}$` / `^[0-9a-fA-F:.]+$` | `CreateNetworkSheet` |
| Tên project Compose | `^[a-z0-9][a-z0-9_-]*$` | `ComposeProject.isValidName` |
| Tên service Compose | `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`, kiểm tra cả khi lấy từ label hoặc `config --services` | `ComposeService.isValidServiceName` |
| Image reference khi pull | `^[a-zA-Z0-9][a-zA-Z0-9._/:@-]*$` | `PullSheet` (`Features/Images/ImagesView.swift`) |
| ID / tên trong URL Docker API | Percent-encode path segment và query | `DockerClient.escape` |
| Tên miền local | Mỗi label `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, nối bằng `.`; chỉ chuỗi đã kiểm tra mới vào Caddyfile | `ProxyRoute.isValidSubdomain` |
| Tên snapshot Elasticsearch | `^[a-z0-9][a-z0-9._-]{0,200}$` | `ElasticsearchSnapshot.isValidName` |
| Tên entry tar khi copy file vào container | Một tên file `^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$`, không có `/`, không có `..` | `TarWriter.isValidEntryName` |
| Thư mục Redis / tên RDB | `dir` phải là đường dẫn tuyệt đối, không có `..`; `dbfilename` theo quy tắc tên entry tar | `DatabaseRestore.parseRedisConfig` |
| Đường dẫn socket | Chỉ nhận đường dẫn tuyệt đối từ `colima status`; kiểm tra độ dài `sun_path` | `ColimaStatus.unixPath`, `DockerClient.connect` |

Đường dẫn trong cột Code tính tương đối từ `Sources/ColimaX/`.

## Secret

- Biến môi trường có tên giống secret (chứa `PASSWORD`, `PASSWD`, `SECRET`, `TOKEN`, `APIKEY`, `API_KEY`, `PRIVATE_KEY`, `ACCESS_KEY`, `CREDENTIAL`, `AUTH`, `DSN`, `CONNECTION_STRING`, hoặc kết thúc bằng `_PASS` / `_PWD` / `_KEY`; trừ `PWD`, `OLDPWD`, `*_FILE`) được **che trong UI** bằng một chuỗi độ dài cố định (`EnvVar.isSensitive`, `EnvVar.maskedValue`). Muốn xem phải bật "Show Secrets"; mục menu "Copy KEY=VALUE" của biến nhạy cảm chỉ dùng được khi đã bật tuỳ chọn này.
- **Security audit không bao giờ đưa giá trị secret vào kết quả**; chỉ liệt kê tên biến (có unit test kiểm tra giá trị không xuất hiện trong `detail` / `recommendation`).
- **Credential database chỉ được dùng bên trong container**: script dump đọc mật khẩu từ biến môi trường của chính container hoặc `*_PASSWORD_FILE` và truyền cho công cụ qua `MYSQL_PWD` / `REDISCLI_AUTH` (biến môi trường, không phải argv). Mật khẩu không bao giờ đi qua app và không bao giờ bị ghi log. stderr của dump bị giới hạn 16 KB để báo lỗi.

## File do app ghi

- Dữ liệu backup (tar volume, dump database): `DockerClient.receiveToFile` ghi vào file tạm trong cùng thư mục, **tạo với quyền 0600**, và chỉ chuyển sang tên đích sau `synchronize()`. Ghi đè file có sẵn dùng `replaceItemAt(..., options: .usingNewMetadataOnly)` để file mới giữ quyền 0600. Nếu lỗi giữa chừng khi truyền, file tạm bị xoá và file đích có sẵn được giữ nguyên.
- Manifest backup và log export được ghi qua `AtomicFile` (`open(O_CREAT | O_EXCL, 0600)` trên file tạm + `rename(2)`), nên cũng có quyền 0600.
- Restore luôn xác minh manifest (kích thước + SHA-256) và cấu trúc tar **trước khi** gọi Docker.

## Xác nhận thao tác destructive

Các thao tác sau hiện hộp thoại xác nhận (`Confirm`) trước khi chạy:

| Màn hình | Thao tác |
|---|---|
| Containers | Xoá container (tuỳ chọn xoá kèm anonymous volume) |
| Images | Xoá image (tuỳ chọn force), prune |
| Volumes | Xoá volume, prune, restore vào volume |
| Networks | Xoá network, prune, disconnect container khỏi network |
| Compose | `down`, rebuild và recreate một service |
| Storage | Prune build cache, prune image dangling / không dùng, xoá container đã dừng, xoá các volume đã chọn |
| Runtime Settings | Xoá profile (tuỳ chọn xoá kèm dữ liệu), áp dụng cấu hình cần tạo lại VM (tuỳ chọn xoá dữ liệu), áp dụng cấu hình khi VM đang chạy (restart) |
| Thanh thao tác | Huỷ một thao tác dài đang chạy |
| Containers | Restore database (**gõ chính xác tên container**), restore snapshot Elasticsearch ở chế độ ghi đè (**gõ chính xác tên container**), xoá snapshot |
| Backups | Xoá lịch backup (file backup được giữ lại) |
| Local Domains | Xoá container proxy, tin cậy CA |

Storage chỉ xoá những volume người dùng đã tick; không bao giờ âm thầm prune tất cả.

## Lịch backup, lịch sử tài nguyên, proxy

- Retention của lịch backup chỉ xoá file **khớp mẫu đặt tên của lịch** (`<source>-YYYYMMDD-HHMMSS.<ext>`) **và** có manifest khớp nguồn và loại; các file khác trong thư mục không bao giờ bị xoá (`BackupRetention`, có unit test).
- Lịch sử tài nguyên lưu ở `~/Library/Application Support/ColimaX/metrics/<profile>.jsonl` (chỉ tên container và số liệu, không có biến môi trường hay secret) và giữ 3 ngày.
- Proxy tên miền local (`colimax-proxy`) chạy với `network_mode: host` **bên trong VM** và chỉ bind vào `127.0.0.1`; nó không tham gia network của người dùng. Private key của CA nội bộ Caddy nằm trong volume `colimax-proxy-data`: ai đọc được volume này, trên máy Mac đã tin cậy CA, có thể cấp certificate mà máy Mac đó chấp nhận. Tin cậy CA là tuỳ chọn và có thể gỡ bằng "Remove Trust" hoặc trong Keychain Access.

## Diagnostics và security audit

Chỉ đọc: inspect container, chạy `lstat` trên socket, đọc cấu hình, và thử `bind()` trên `127.0.0.1` để phát hiện port đang bị dùng. Nó **không bao giờ tự thay đổi** cấu hình container, socket hay Colima; chỉ đưa ra khuyến nghị.

## Giới hạn đã biết

- Không có App Sandbox: app có quyền của người dùng đang đăng nhập.
- Stop / Restart VM (toolbar, Dashboard, menu bar) và dừng container không hỏi xác nhận, dù chúng dừng các container đang chạy.
- Phát hiện secret dựa trên **tên biến**; giá trị nhạy cảm nằm trong biến có tên bình thường sẽ không được che.
- Dump database là plaintext, không mã hoá. Người dùng tự chịu trách nhiệm bảo vệ nơi lưu trữ.
- File `.command` dùng để mở Terminal nằm lại trong thư mục tạm và không được tự động xoá.
- Chưa có test tự động cho quyền file sau khi ghi đè một backup có sẵn.
- `scripts/build-app.sh` mặc định ký ad-hoc (chỉ dùng nội bộ). Bản phát hành phải đi qua `scripts/release.sh`: ký Developer ID với secure timestamp, notarize và staple cả app lẫn DMG, kèm checksum SHA-256 ([docs/RELEASE.vi.md](docs/RELEASE.vi.md)).
- Trong lúc restore, file dump trong `/tmp` của container có quyền 0644 (để image chạy bằng user không phải root vẫn đọc được); file bị xoá ngay khi restore xong.

## Báo cáo lỗ hổng

Báo cáo lỗ hổng **một cách riêng tư** qua GitHub: tab **Security → Report a vulnerability** của repository (GitHub private vulnerability reporting). Không mở issue công khai, và không công bố chi tiết trước khi có bản sửa.

Vui lòng gửi kèm: phiên bản ColimaX, phiên bản macOS, mô tả và các bước tái hiện, cùng mức độ ảnh hưởng. Maintainer sẽ xác nhận đã nhận trong vòng 7 ngày và chia sẻ kế hoạch sửa; nếu người báo cáo đồng ý, lỗ hổng sẽ được ghi công trong release notes.

Phiên bản được hỗ trợ sửa lỗi bảo mật: bản phát hành mới nhất.
