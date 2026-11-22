# ColimaX 1.0.0 — Đánh giá kỹ thuật

[English](AUDIT.md) · Tiếng Việt

Đây là bản đánh giá kỹ thuật của phiên bản 1.0.0: thiết lập build, kiến trúc, các rủi ro kỹ thuật đã xử lý trong thiết kế, các vấn đề còn mở, và bảng khoảng trống có xếp ưu tiên. Trạng thái tính năng và kết quả test được theo dõi trong [FEATURES.vi.md](FEATURES.vi.md).

## 1. Thiết lập dự án

| Hạng mục | Trạng thái |
|---|---|
| Build | `scripts/dev-build.sh` (`swiftc -swift-version 6`, strict concurrency), 0 warning |
| Test | Unit test XCTest, integration test chạy với VM Colima thật, UI test XCUITest chạy với fixture. Kết quả: [FEATURES.vi.md](FEATURES.vi.md#verify) |
| Project Xcode | Không có cho app. `Package.swift` (executable target `ColimaX`, test target `ColimaXTests`, macOS 14); `UITests/ColimaXUITests.xcodeproj` chỉ dùng để chạy UI test |
| Info.plist / ký | Sinh bởi `scripts/build-app.sh`: bundle ID mặc định `dev.colimax.ColimaX`, không App Sandbox, Hardened Runtime, không entitlement, mặc định ký ad-hoc |
| Phụ thuộc | Không có package ngoài |
| Icon app | `Resources/AppIcon.icns`, đóng gói qua `CFBundleIconFile` (T4) |

## 2. Kiến trúc

Chi tiết trong [ARCHITECTURE.vi.md](ARCHITECTURE.vi.md). Tóm tắt đánh giá:

- **Các tầng:** View → Store (`@MainActor @Observable`) → protocol service → Service (static enum / struct `Sendable`). Service không import SwiftUI.
- **MVVM:** `AppStore` là composition root (profile, dữ liệu Docker, kết nối / events, điều hướng). Thao tác dài nằm trong `OperationCenter`; mỗi màn hình có model riêng (`ContainersModel`, `RuntimeModel`, `DiagnosticsModel`, …) (T7).
- **DI:** View lấy Store qua `@Environment`. Store gọi Docker và Colima qua protocol `DockerEngine` / `ColimaControlling`, inject qua `AppServices`, có fake trong bộ nhớ cho test (T6). Các store chạy nền phụ thuộc vào host protocol hẹp thay vì `AppStore` (T8).
- **Concurrency:** state UI trên MainActor; I/O blocking trên GCD qua `BlockingIO`; timeout và huỷ cho process và socket.
- **Realtime:** Docker `/events` gộp trong 300 ms, kqueue trên `_lima` debounce 600 ms, poll dự phòng 30 s.

Không thấy retain cycle gây rò rỉ: các `Task` capture `AppStore`, nhưng Store sống suốt vòng đời app. Không có race trên state UI vì toàn bộ nằm trên MainActor.

## 3. Rủi ro kỹ thuật đã xử lý trong thiết kế 1.0.0

Cột Vị trí ghi file và tên symbol để không lệch khi code thay đổi.

| # | Mức độ | Rủi ro | Cách giảm thiểu trong 1.0.0 | Vị trí |
|---|---|---|---|---|
| R1 | P0 | Blocking I/O (`recv`, chờ process) chiếm cooperative thread pool và có thể làm treo mọi async task | `BlockingIO.run` chạy việc blocking trên một `DispatchQueue` concurrent riêng; `ProcessExecution` đọc pipe trên GCD và chờ qua `terminationHandler` | `Core/BlockingIO.swift` (`BlockingIO`), `Core/Docker/DockerClient.swift` (`connection`), `Core/Shell.swift` (`ProcessExecution`) |
| R2 | P0 | Process bị treo (ví dụ `colima ssh`) không có timeout, không huỷ được, và để lại process mồ côi | `Shell.run` có timeout (mặc định 120 s, colima 15–30 s); huỷ Task sẽ gọi `terminate()`; lỗi `ShellError.timedOut` / `CancellationError` | `Core/Shell.swift` (`Shell.run`, `ProcessExecution.run`) |
| R3 | P0 | Request Docker không huỷ được và phải chờ `SO_RCVTIMEO` hết hạn | `SocketHandle` gọi `shutdown(fd, SHUT_RDWR)` khi Task bị huỷ | `Core/Docker/DockerClient.swift` (`SocketHandle`) |
| R4 | P0 (an toàn dữ liệu) | Backup nuốt lỗi ghi (đầy disk), tạo ra file tar bị cắt cụt nhưng báo thành công; lỗi giữa chừng để lại file dở dang | `receiveToFile` ghi file tạm 0600 trong cùng thư mục, SHA-256 tăng dần, `synchronize()`, rồi thay thế file đích; nếu thất bại thì xoá file tạm. `AtomicFile` cho manifest / log | `Core/Docker/DockerClient.swift` (`receiveToFile`), `Features/Backup/BackupService.swift` (`AtomicFile`) |
| R5 | P0 | Đường dẫn Docker socket hardcode, sai khi Colima đổi chỗ socket | Đọc `docker_socket` từ `colima status --json`; fallback về `$COLIMA_HOME/<profile>/docker.sock` | `Core/Colima/ColimaService.swift` (`status`, `resolveDockerSocket`), `App/AppStore.swift` (`resolveEndpoint`) |
| R6 | P1 | Thao tác chạy lâu không huỷ được; process bị kill bằng signal bị coi là thành công | Nút Cancel có xác nhận trong `OperationPanel`; trạng thái `cancelled` riêng; `Shell.stream` coi việc thoát do signal là lỗi | `Core/Shell.swift` (`uncaughtSignal` branch in `Shell.stream`), `App/OperationCenter.swift` (`runOperation`), `UI/Components.swift` (`OperationPanel`) |
| R7 | P1 | Trình xem log gán lại toàn bộ chuỗi (tới 2 MB) mỗi lần cập nhật và layout lại cả tài liệu | `CodeTextView` chỉ nối phần mới vào `NSTextStorage` khi nội dung chỉ tăng thêm | `UI/Components.swift` (`CodeTextView`) |
| R8 | P1 | Mỗi lần render cell lại tạo formatter mới | Formatter static dùng chung trong `Format` | `Core/Utilities.swift` (`Format`) |
| R9 | P1 | `Shell.which` bỏ qua `PATH` (MacPorts, Nix) | Tìm trong các đường dẫn Homebrew, sau đó tới `PATH` của process; từ chối tên chứa `/` | `Core/Shell.swift` (`Shell.which`) |
| R10 | P2 | Một endpoint Docker lỗi chặn việc cập nhật các loại dữ liệu khác | `AppStore.reload` tải từng loại độc lập | `App/AppStore.swift` (`reload`) |
| R11 | P2 | Transcript Exec tăng không giới hạn | Cắt về 250.000 byte khi vượt 500.000 byte | `Features/Containers/ContainersView.swift` (exec transcript) |
| R12 | P2 | Container helper của backup bị bỏ lại khi app bị kill giữa chừng | `VolumeBackup.cleanupStaleHelpers` xoá helper có label `dev.colimax.helper`, state `created`, cũ hơn 10 phút, ở mỗi lần kết nối Docker | `Features/Backup/BackupService.swift` (`cleanupStaleHelpers`) |

Mọi đường dẫn tính từ `Sources/ColimaX/`.

Độ phủ test: R1–R4, R6 và R9 có unit test trong `ShellTests` / `DockerClientTests` / `OperationTests`. R3 (huỷ log stream), R4 (truyền file), R5 (endpoint) và R12 (`testCleanupStaleHelpersOnlyRemovesTestHelpers`) có integration test. R7, R8, R10 và R11 chưa có test tự động.

## 4. Vấn đề còn mở

Không có. Các vấn đề review phát hiện và đã xử lý: tách model theo màn hình khỏi `AppStore` (T7); protocol service kèm fake (T6); UI test cho xác nhận thao tác phá huỷ và che secret (T9, T10); backup MySQL / MariaDB / PostgreSQL đã chạy với container thật (G9); hỏi xác nhận trước khi stop / restart VM khi còn container chạy (`VMControl`; dừng một container vẫn là một click vì Start là khôi phục được); bản địa hoá (G18); icon app (T4).

## 5. Khoảng trống và ưu tiên

Điểm 1–5: V = giá trị với người dùng, C = độ phức tạp, R = rủi ro. Mọi mục dưới đây đều có trong 1.0.0; trạng thái và test hiện tại nằm trong [FEATURES.vi.md](FEATURES.vi.md).

| ID | Tính năng | V | C | R | Ưu tiên | API / CLI |
|---|---|---|---|---|---|---|
| G1 | I/O không block, tách khỏi pool + timeout + huỷ (R1–R3) | 5 | 2 | 2 | **P0** | — |
| G2 | Resolve Docker endpoint từ `colima status --json` (R5) | 5 | 2 | 1 | **P0** | `colima status --json` → `docker_socket` |
| G3 | Backup an toàn: file tạm + rename, báo lỗi ghi (R4) | 5 | 1 | 1 | **P0** | `/archive` |
| G4 | Huỷ thao tác chạy lâu, trạng thái "Cancelled" (R6) | 4 | 2 | 1 | **P0** | — |
| G5 | Hiệu năng trình xem log / formatter / `which` (R7–R9) | 3 | 1 | 1 | **P0** | — |
| G6 | Chi tiết container: restart count, OOMKilled, exit code, health, limit, env (che secret), mount, IP | 5 | 2 | 1 | **P1** | `GET /containers/{id}/json` |
| G7 | Export log ra file | 4 | 1 | 1 | **P1** | — |
| G8 | Manifest backup + SHA-256 + xác minh trước khi restore | 5 | 2 | 1 | **P1** | CryptoKit |
| G9 | Logic backup database: MySQL / MariaDB, PostgreSQL, Redis | 5 | 3 | 2 | **P1** | exec API (tách stdout / stderr) |
| G10 | Diagnostics: CLI, ping endpoint, Docker context, lệch cấu hình, VZ / virtiofs / Rosetta, gợi ý tài nguyên | 4 | 2 | 1 | **P1** | colima, `/_ping`, `~/.docker` |
| G11 | Apple Silicon: kiến trúc image, cảnh báo giả lập amd64 | 4 | 2 | 1 | **P1** | `GET /images/{id}/json` |
| G12 | Security audit: privileged, capability nguy hiểm, mount docker.sock, host network / pid, bind 0.0.0.0, env giống secret, quyền socket | 4 | 2 | 1 | **P1** | inspect |
| G13 | Storage: volume mồ côi, image không dùng, build cache, gợi ý dọn dẹp | 4 | 2 | 2 | **P1** | `/system/df`, `/build/prune` |
| G14 | Connect / disconnect container với network | 3 | 1 | 1 | **P1** | `/networks/{id}/connect` |
| G15 | Compose: tìm file + `.env`, validate, xem config, log, restart / rebuild từng service | 4 | 2 | 2 | **P1** | `docker compose config/logs/up <svc>` |
| G16 | Xung đột port (port của container đã dừng bị process trên host chiếm) | 3 | 2 | 1 | **P1** | thử `bind()` |
| G17 | Phím tắt ⌘1…⌘9 để chuyển màn hình | 3 | 1 | 1 | **P1** | — |
| G18 | Bản địa hoá (tiếng Anh + tiếng Việt) | 3 | 3 | 2 | P2 | String Catalog |
| G19 | Lịch backup + giới hạn số bản giữ lại | 3 | 3 | 2 | P2 | launchd / timer |
| G20 | Cảnh báo ngưỡng tài nguyên, lưu lịch sử | 3 | 3 | 1 | P2 | — |
| G21 | Restore dump database | 4 | 3 | **4** | P2 | — (destructive) |
| G22 | Topology network, đồ thị phụ thuộc Compose | 2 | 4 | 1 | P3 | — |
| G23 | Domain local, reverse proxy, HTTPS local | 3 | 5 | 4 | P3 | Caddy / Traefik |
| G24 | Quét lỗ hổng image (Trivy / Docker Scout) | 3 | 3 | 2 | P3 | CLI ngoài |
| G25 | Snapshot Elasticsearch | 2 | 4 | 3 | P3 | cần `path.repo` |

## 6. UX / UI

- **Điểm mạnh:** `NavigationSplitView` với sidebar bốn nhóm; `Table` sắp xếp được; context menu; `ContentUnavailableView` cho trạng thái rỗng; xác nhận thao tác destructive; theme System / Light / Dark; ⌘1…⌘9; Diagnostics và Security gộp chung một màn hình; Storage có các thao tác dọn dẹp kèm xác nhận; icon health trong cột Status của Containers.
- **Hạn chế:**
  - lỗi chủ yếu hiển thị qua một banner chung chung;
  - restart count chỉ thấy trong pane chi tiết, không có cột riêng.
