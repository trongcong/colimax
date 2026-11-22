# Kiến trúc ColimaX

[English](ARCHITECTURE.md) · Tiếng Việt

Tài liệu này mô tả kiến trúc của phiên bản 1.0.0. Trạng thái tính năng được theo dõi trong [FEATURES.vi.md](FEATURES.vi.md). Bản đánh giá kỹ thuật nằm trong [AUDIT.vi.md](AUDIT.vi.md).

## 1. Các tầng

```
ColimaXApp (@main)
 ├─ Window "main"  → MainWindow (NavigationSplitView, 14 screens)
 ├─ MenuBarExtra   → MenuContentView
 └─ Settings       → PreferencesView
        │  @Environment
        ▼
Views (SwiftUI)                       DiagnosticsModel (dedicated view model for the Diagnostics screen)
        │
        ▼
Stores — @MainActor @Observable
 ├─ AppStore      profiles, Docker data, events / reloads, navigation (composition root)
 │   ├─ operations  OperationCenter: long operation + log, cancel, busy keys, errors, flash
 │   ├─ runtimeModel / setupModel                         (ProfileContext)
 │   ├─ containersModel / composeModel / imagesModel /
 │   │  volumesModel / networksModel / storageModel         (DockerContext)
 │   ├─ scheduler  BackupScheduler: backup schedules (60 s timer)       (BackupSchedulerHost)
 │   ├─ resources  ResourceWatcher: 60 s background sampling, alerts    (ResourceWatcherHost)
 │   └─ proxy      ProxyStore: *.localhost routes, Caddy container      (ProxyHost)
 ├─ AppSettings   UserDefaults (theme, Dock icon, VM auto-start, notifications)
 └─ MonitorStore  per-container stats stream
        │
        ▼
Service protocols (AppServices: .live / fakes)
 ├─ ColimaControlling   LiveColima → ColimaService            (FakeColima)
 └─ DockerEngine        DockerClient                          (FakeDocker)
        │
        ▼
Services — static enums / Sendable structs, no UI state
 ├─ Shell / ProcessExecution   Process + argument array, timeout, cancellation
 ├─ ColimaService              colima list/status/start/stop/delete, colima.yaml, vmUsage
 ├─ DockerClient (+ DockerAPI) HTTP/1.0 over a unix socket: buffered, streaming, file transfer
 ├─ ContainerDetails           container inspect model, EnvVar, ImagePlatform, HostPlatform
 ├─ BackupService              AtomicFile, BackupManifest, BackupVerifier, TarInspector,
 │                             VolumeBackup, DatabaseEngine, DatabaseBackup
 ├─ Diagnostics                RuntimeDiagnostics, ImageArchDiagnostics, SecurityAudit,
 │                             PortDiagnostics, PortProbe, DockerContextReader, StorageReport
 ├─ DatabaseRestore            restore a dump into a container, TarWriter
 ├─ BackupSchedule             schedules + BackupRetention (pure)
 ├─ ResourceAlerts             AlertEvaluator, MetricsHistory (JSONL)
 ├─ VulnerabilityScanner       Trivy / Docker Scout (CLI installed by the user)
 ├─ ElasticsearchSnapshot      snapshot API via curl inside the container
 ├─ Topology                   NetworkTopology, ComposeDependencyGraph
 ├─ LocalProxy                 Caddyfile, proxy container, root CA, TarReader
 ├─ ComposeService             docker compose CLI, ComposeDiscovery
 └─ SystemIntegration          Notifier, LaunchAtLogin, TerminalLauncher, DirectoryWatcher
        │
        ▼
Colima CLI (Process)       Docker Engine API (unix socket, HTTP/1.0)       docker CLI (Compose, Terminal)
```

Quy tắc phụ thuộc: View → Store (hoặc model màn hình) → Service. Service không import SwiftUI và không biết gì về Store. Logic thuần (parser, validator, hàm kiểm tra) nằm ở Service để có thể test trực tiếp với fixture.

Store không gọi thẳng Colima hay Docker: mọi lời gọi đi qua `AppServices` (`colima: any ColimaControlling`, `makeDocker: (socketPath) -> any DockerEngine`, kiểm tra / cài công cụ, `notify` để gửi thông báo cho người dùng, `scannerTools` cho các scanner lỗ hổng đã cài). `AppServices.live` nối CLI và socket thật; `AppServices.forLaunch()` trả về fixture UI test khi app được build với `-D COLIMAX_UI_TESTING` và chạy với `COLIMAX_UI_TEST_FIXTURES=1`. Mọi service nhận `any DockerEngine`, kể cả truyền file và archive (backup / restore volume và database, backup theo lịch, proxy local, export Elasticsearch), nên tất cả chạy được với `FakeDocker` trong unit test (`TransferFakeTests`); integration test vẫn phủ hành vi Docker thật.

### Bố cục mã nguồn

Sơ đồ trên nhóm các kiểu theo vai trò. Trên đĩa, `Sources/ColimaX` được tổ chức theo tính năng; mỗi thư mục có thể chứa kiểu thuộc nhiều tầng.

| Thư mục | Nội dung | Vai trò trong các tầng |
|---|---|---|
| `App/` | `ColimaXApp`, `MainWindow`, `MenuContentView`, `PreferencesView`, `AppStore`, `AppSettings`, `OperationCenter`, `AppServices` (+ protocol `DockerContext`, `ProfileContext`, `…Host`) | Composition root và state toàn cục: entry point của app, cửa sổ và scene, các store dùng chung, inject service |
| `Core/` | `Shell`, `BlockingIO`, `Hashing`, `Utilities`, `SystemIntegration` | Service hạ tầng dùng chung cho mọi tính năng: chạy process, blocking I/O, hashing, định dạng, tích hợp macOS |
| `Core/Docker/` | `DockerEngine` (protocol), `DockerClient`, `DockerAPI`, `DockerModels`, `ContainerDetails` | Client Docker Engine API và các model của nó |
| `Core/Colima/` | `ColimaControlling` (protocol), `LiveColima`, `ColimaService` | Client Colima CLI và model |
| `Testing/` | `Fakes.swift`: `FakeColima`, `FakeDocker`, `FakePrerequisites`, `UITestFixtures`, `UITestScenario` | Fake trong bộ nhớ, chỉ biên dịch với `-D COLIMAX_UI_TESTING` (unit test, app UI test); không bao giờ có trong bản release |
| `UI/` | `Components.swift` | Component SwiftUI dùng chung (`CodeTextView`, `OperationPanel`, …) |
| `Features/<Name>/` | Mỗi tính năng một thư mục: Dashboard, Runtime, Containers, Compose, Images, Volumes, Networks, Backup, Monitoring, Diagnostics, LocalDomains, Setup | View của tính năng, model màn hình (`RuntimeModel`, `ContainersModel`, `ComposeModel`, `ImagesModel`, `VolumesModel`, `NetworksModel`, `StorageModel`, `SetupModel`), cùng store riêng của tính năng (ví dụ `BackupScheduler`, `MonitorStore`, `ResourceWatcher`, `ProxyStore`) và service (ví dụ `BackupService`, `ComposeService`, `LocalProxy`, `Topology`) |

Quy tắc phụ thuộc vẫn áp dụng bên trong và giữa các thư mục: view của một tính năng phụ thuộc vào store, store phụ thuộc vào service, còn service (trong `Core/` hay trong thư mục tính năng) không bao giờ phụ thuộc vào store hay SwiftUI. Các tính năng dùng `Core/` và `UI/`; `App/` nối các tính năng lại với nhau.

## 2. Concurrency

| Cơ chế | Ở đâu | Ghi chú |
|---|---|---|
| `@MainActor` | Toàn bộ UI state (`AppStore`, `OperationCenter`, model màn hình, `AppSettings`, `MonitorStore`, `DiagnosticsModel`) | Không có race trên UI state |
| `BlockingIO.run` (`Sources/ColimaX/Core/BlockingIO.swift`) | `recv` / `send` trên socket, băm SHA-256 (`FileHasher`), port probe | Chạy trên một `DispatchQueue` concurrent riêng, không dùng `Task.detached`. Cooperative pool chỉ có khoảng một thread mỗi core; chỉ vài lời gọi `recv` block lâu là đủ làm treo mọi async task khác. `onCancel` gỡ block cho thread đang chờ |
| `ProcessExecution` (`Sources/ColimaX/Core/Shell.swift`) | `Shell.run` | Đọc stdout / stderr trên thread GCD và chờ process kết thúc qua `terminationHandler`. Timeout mặc định 120 s; lời gọi colima dùng 15–30 s. Huỷ Task sẽ gọi `terminate()`. Kết quả lỗi: `CancellationError` hoặc `ShellError.timedOut` |
| `Shell.stream` | colima start / stop / delete, docker compose | Stream từng dòng. Nếu phía tiêu thụ huỷ, process bị terminate. Process kết thúc do signal bị coi là thất bại |
| `SocketHandle` (`Sources/ColimaX/Core/Docker/DockerClient.swift`) | Mọi request Docker | Huỷ Task sẽ gọi `shutdown(fd, SHUT_RDWR)` để `recv` đang chờ trả về ngay thay vì đợi `SO_RCVTIMEO` |
| `AtomicFile` (`Sources/ColimaX/Features/Backup/BackupService.swift`) | Manifest backup, export log | `open(O_CREAT \| O_EXCL, 0600)` trên file tạm trong cùng thư mục, `synchronize()`, rồi `rename(2)` |
| Thao tác chạy lâu | `OperationCenter.launch` / `cancelOperation` / `runOperation` | Mỗi lúc chỉ một `operationTask`; nút Cancel (có xác nhận) trong `OperationPanel`; trạng thái `OperationState.Status.cancelled` tách biệt với thành công / thất bại |

### Cập nhật realtime

- Docker: `GET /events` (container, image, volume, network). Mỗi event đánh dấu loại dữ liệu cần tải lại; event được gộp trong 300 ms rồi tải lại một lần. Mỗi loại tải lại độc lập, nên một endpoint lỗi không chặn các loại khác (`AppStore.reload`).
- Nếu stream events bị ngắt: chờ 3 s, chạy `refreshProfiles`, và kết nối lại nếu VM vẫn đang chạy.
- Colima không có event API: `DirectoryWatcher` (kqueue qua `DispatchSource`) theo dõi `~/.colima/_lima` và thư mục của từng instance; thay đổi được debounce 600 ms rồi mới chạy `colima list`. Polling `colima list` mỗi 30 s chỉ là phương án dự phòng.
- Chỉ số tài nguyên chỉ được lấy mẫu khi màn hình đang mở: Dashboard mỗi 15 s, tạm dừng khi cửa sổ bị thu nhỏ, ẩn hoặc bị che (`colima ssh` đọc `/proc`, `df`), Monitoring qua stream `/stats`.

## 3. Docker endpoint

1. Khi một profile chuyển sang running, `AppStore.connectDocker` gọi `resolveEndpoint()`, tức `colima status --profile <p> --json`.
2. `ColimaStatus.dockerSocketPath` lấy trường `docker_socket` và bỏ tiền tố `unix://`; `ColimaStatus.unixPath` chỉ chấp nhận đường dẫn tuyệt đối.
3. `ColimaService.resolveDockerSocket` dùng giá trị đó; nếu `colima status` lỗi hoặc không trả về socket, nó quay về quy ước `$COLIMA_HOME/<profile>/docker.sock` (mặc định `~/.colima`).
4. Mọi client (`AppStore.docker`, Compose, Terminal, Diagnostics) dùng chung `AppStore.socketPath`. Compose và Terminal nhận giá trị này qua `DOCKER_HOST=unix://…`, nên không phụ thuộc vào Docker context của CLI.
5. Diagnostics đọc `~/.docker/config.json` và `contexts/meta/*/meta.json` (`DockerContextReader`) để báo khi context của CLI trỏ sang nơi khác. Việc này chỉ mang tính thông tin; không sửa gì cả.

`DockerClient` dùng HTTP/1.0: daemon không chunk response và tự đóng kết nối, nên stream chỉ cần đọc đến EOF. Hàm `dechunk` dự phòng vẫn còn. Path segment và giá trị query luôn được percent-encode (`DockerClient.escape`).

## 4. Pipeline backup

### Volume (`VolumeBackup`)

```
createHelper: busybox:latest, label dev.colimax.helper, bind <volume>:/volume[:ro], not started
  → GET /containers/{id}/archive?path=/volume
  → receiveToFile: temporary file ".<name>.partial-xxxxxxxx" (0600) in the same directory
                   write chunk by chunk + incremental SHA-256, synchronize()
                   success → replaceItemAt(.usingNewMetadataOnly) or moveItem to the destination
                   failure → delete the temporary file; the existing destination file is untouched
  → remove helper
  → write <file>.manifest.json via AtomicFile
```

Manifest (`BackupManifest`, `format = 1`): `kind` (volume / mysql / mariadb / postgres / redis), `source`, `image`, `createdAt`, `fileName`, `size`, `sha256`, `tool` (`ColimaX <version>`).

Restore chạy theo thứ tự, và mọi bước kiểm tra đều chạy trước bất kỳ lời gọi Docker nào:

1. `BackupVerifier.verify`: nếu có manifest thì so sánh kích thước và SHA-256; từ chối manifest hỏng hoặc manifest có `format` mới hơn app. Vẫn cho phép restore khi không có manifest, nhưng UI nói rõ là file không thể xác minh.
2. Manifest (nếu có) phải có `kind == volume`.
3. `TarInspector.validateVolumeArchive`: tar header đầu tiên phải là thư mục `volume/` (ustar).
4. Tạo volume nếu chưa có → helper ghi được → `PUT /containers/{id}/archive?path=/` → xoá helper.

Helper bị bỏ lại khi app bị kill giữa chừng (label `dev.colimax.helper`, state `created`, cũ hơn 10 phút) được `VolumeBackup.cleanupStaleHelpers` dọn ở mỗi lần kết nối Docker.

### Database (`DatabaseBackup`)

- `DatabaseEngine.detect` nhận diện engine từ tên repository của image: MySQL / Percona, MariaDB, PostgreSQL (postgis, timescaledb), Redis / Valkey / KeyDB.
- Container phải đang chạy (`BackupError.containerNotRunning`).
- `POST /containers/{id}/exec` với `sh -c <DatabaseEngine.script>`; script là hằng số.
- `DockerClient.execToFile` tách stream: stdout được ghi ra file (cùng cơ chế file tạm + SHA-256), stderr giữ trong bộ nhớ tối đa 16 KB để báo lỗi.
- Kiểm tra: exit code 0, file không rỗng, có dấu hiệu hoàn tất (`Dump completed` với MySQL / MariaDB, `PostgreSQL database cluster dump complete`, header `REDIS` với RDB). Nếu thất bại, file bị xoá và lỗi được báo.
- Manifest được ghi như với volume. PostgreSQL dùng `pg_dumpall --clean --if-exists` để dump có thể restore vào một cluster đã tồn tại.

### Restore database (`DatabaseRestore`, G21)

1. `preflight` (không đụng tới Docker): `BackupVerifier.verify`; manifest (nếu có) phải cùng họ engine (MySQL ↔ MariaDB tính là một họ); `engine.validate` trên phần đầu / cuối file để từ chối dump bị cắt cụt.
2. UI yêu cầu xác nhận bằng cách **gõ tên container** (`Confirm.typed`).
3. MySQL / MariaDB / PostgreSQL: `DockerClient.uploadAsTar` bọc file thành tar một entry **ngay khi truyền** (không tạo file tar tạm) và `PUT /archive` tới `/tmp/colimax-restore.dump`; sau đó exec một script hằng (`mysql` / `mariadb` / `psql -f`) có `trap` xoá file. Lỗi psql không chặn được trả về dưới dạng cảnh báo ("role already exists" được bỏ qua).
4. Redis / Valkey: đọc `dir`, `dbfilename`, `appendonly` qua `CONFIG GET`; từ chối khi bật AOF; stop container → upload RDB vào `dir` → start (container vẫn được khởi động lại kể cả khi upload thất bại).

### Lịch backup (`BackupScheduler`, G19)

- Lịch được lưu trong `UserDefaults` (`backupSchedules`). Một timer trong app kiểm tra mỗi 60 s và chạy tuần tự các lịch đến hạn của profile đang chạy. Nếu thất bại, lịch thử lại sau `min(interval, 15 minutes)`.
- Lịch database chọn container theo **tên** (Compose tạo lại container sẽ đổi ID).
- Tên file theo dạng `<source>-YYYYMMDD-HHMMSS.<ext>` (UTC). `BackupRetention` chỉ xét các file khớp mẫu tên **và** có manifest khớp source và kind.

## 5. Giám sát nền và cảnh báo (G20)

- `ResourceWatcher` (bật trong Preferences → Background monitoring) gọi `GET /containers/{id}/stats?stream=0` mỗi 60 s cho các container đang chạy (tối đa 6 song song).
- CPU được chuẩn hoá thành phần trăm của toàn VM (`cpuPercent / online_cpus`); memory là phần trăm của limit.
- Mẫu được ghi nối dạng JSONL vào `~/Library/Application Support/ColimaX/metrics/<profile>.jsonl` qua `BlockingIO`; việc cắt bớt về 3 ngày chạy mỗi giờ.
- `AlertEvaluator` (thuần): cảnh báo khi N mẫu liên tiếp vượt ngưỡng, và chỉ một lần cho đến khi giá trị xuống dưới 90% ngưỡng. Disk của VM được đo mỗi 10 phút qua `colima ssh`.

## 6. Proxy domain local (G23)

```
Mac: https://web.localhost:443 ──(Colima port forward 127.0.0.1)──▶ VM 127.0.0.1:443
   ▶ container colimax-proxy (caddy:2-alpine, network_mode: host)
   ▶ reverse_proxy <container IP on its network>:<port>
```

- Caddyfile được sinh từ các route đã validate: `default_bind 127.0.0.1`, `http_port` / `https_port`, `local_certs` (hoặc `auto_https off`). File được ghi bằng `uploadAsTar`, sau đó chạy `caddy reload`.
- Khi một container đích restart (event `start`), cấu hình được áp dụng lại sau 2 s vì IP của nó có thể đã đổi.
- Root CA được đọc từ `/data/caddy/pki/authorities/local/root.crt` (volume `colimax-proxy-data`) qua archive API (`TarReader`).

## 7. Diagnostics

`DiagnosticsModel.run` (`Sources/ColimaX/Features/Diagnostics/DiagnosticsView.swift`) thu thập mọi I/O một lần (`colima status`, `/_ping`, `lstat` socket, Docker context, `colima.yaml`, CPU / memory của host, inspect container và image, port probe) vào một snapshot. Các bước kiểm tra là hàm thuần nhận snapshot và trả về `[DiagnosticItem]`:

| Hàm | Đầu vào | Kiểm tra |
|---|---|---|
| `RuntimeDiagnostics.check` | `RuntimeSnapshot` | CLI, endpoint, ping, quyền socket, Docker context, lệch cấu hình, tài nguyên, VZ / virtiofs / Rosetta, disk VM, app chạy dưới Rosetta |
| `ImageArchDiagnostics.check` | image, platform, container, Rosetta, kiến trúc VM | Image / container không phải arm64 |
| `SecurityAudit.check` | `[ContainerDetails]`, VM có IP riêng hay không | privileged, capability nguy hiểm, mount `docker.sock`, host network / pid / ipc, `unconfined`, port bind vào `0.0.0.0`, tên biến env trông giống secret |
| `PortDiagnostics.check` | `[ContainerDetails]`, closure `isInUse` | Port khai báo trùng nhau, port của container đã dừng nhưng đang bị chiếm |
| `StorageReport.analyze` | `/system/df`, container | Dữ liệu cho màn Storage |

Cách tách này cho phép unit test bằng fixture, không cần Docker thật. Không hàm nào trong số này sửa cấu hình.

## 8. Điểm nối để test và cách thêm tính năng

Mọi store đều chạy được mà không cần VM. Các điểm nối:

| Điểm nối | Bản thật | Fake (`Sources/ColimaX/Testing/Fakes.swift`, chỉ khi có `-D COLIMAX_UI_TESTING`) |
|---|---|---|
| `ColimaControlling` | `LiveColima` → `ColimaService` (colima CLI) | `FakeColima`: profile trong bộ nhớ, ghi lại lời gọi, có thể cho stream vòng đời thất bại |
| `DockerEngine` | `DockerClient` (unix socket) | `FakeDocker`: container / image / volume / network / chi tiết inspect trong bộ nhớ, ghi lại lời gọi thay đổi dữ liệu, phát `/events`, lỗi theo từng endpoint |
| `AppServices` | `.live` | `UITestFixtures.services()` (app UI test), hoặc tự dựng trong unit test |
| `DockerContext` / `ProfileContext` | `AppStore` | Một class nhỏ bất kỳ; model màn hình chỉ thấy các protocol này |
| `BackupSchedulerHost` / `ResourceWatcherHost` / `ProxyHost` | `AppStore` | Một class nhỏ bất kỳ; store chạy nền giữ tham chiếu `weak` tới protocol, không tới `AppStore` |

Unit test (`Tests/ColimaXTests/StoreTests.swift`) dựng `AppStore(settings:services:)` với `FakeColima` / `FakeDocker` và kiểm reload, xoá lỗi, gộp event, thao tác VM, khoá busy và các model màn hình. `scripts/run-tests.sh` biên dịch với `-D COLIMAX_UI_TESTING` để có fake. UI test (`UITests/`, chạy bằng `scripts/ui-tests.sh`) điều khiển một app bundle riêng, `build/ColimaX-UITest.app` (bundle ID `dev.colimax.ColimaX.uitest`, nên UserDefaults không đụng tới app thật), khởi chạy với `COLIMAX_UI_TEST_FIXTURES=1` và tuỳ chọn một kịch bản fixture (`COLIMAX_UI_TEST_SCENARIO`, xem `UITestScenario`); xem [TESTING.vi.md](TESTING.vi.md).

### Thêm một màn hình tính năng

1. Đặt logic thuần (parse, validate, dựng request) trong service ở `Features/<Name>/` hoặc `Core/`, kèm unit test với fixture.
2. Nếu màn hình cần lời gọi Docker hoặc Colima mới, thêm vào `DockerEngine` / `ColimaControlling`, implement trong `DockerClient` / `LiveColima` và trong `FakeDocker` / `FakeColima`.
3. Thêm model màn hình `@MainActor` `Features/<Name>/<Name>Model.swift` nhận `unowned let context: any DockerContext` (hoặc `ProfileContext`). Chạy action qua `context.operations` (`perform(key)` cho action ngắn, `launch` + `runOperation` cho thao tác dài) để trạng thái busy, lỗi, huỷ và log thao tác hoạt động giống nhau ở mọi nơi. Chỉ đánh dấu `@Observable` khi model giữ state.
4. Nếu model cần thêm gì từ app, mở rộng protocol context hẹp nhất (và phần conform của `AppStore`) thay vì truyền `AppStore`.
5. Đưa nó ra thành `lazy var <name>Model` trên `AppStore`; view đọc `store.<name>Model`.
6. Thao tác destructive xác nhận trong view (`Confirm.destructive` / `Confirm.typed`) trước khi gọi model. Gắn `accessibilityIdentifier` cho control quan trọng và thêm UI test với fixture khi luồng là destructive hoặc hiển thị secret.
7. Thêm unit test dùng fake, cập nhật `docs/FEATURES.md` (+ `.vi.md`) và thêm chuỗi UI vào `Resources/vi.lproj`.

## 9. Quyết định thiết kế

### ADR-1: Không bật App Sandbox

- **Bối cảnh:** app phải chạy `colima`, `limactl` và `docker` cài qua Homebrew, và kết nối tới unix socket trong `~/.colima`.
- **Quyết định:** không bật App Sandbox; bật Hardened Runtime, không có entitlement.
- **Hệ quả:** app không thể phát hành qua Mac App Store và chạy với quyền của user đang đăng nhập. Rủi ro được giảm nhờ validate input, không nối chuỗi lệnh shell, và xác nhận thao tác destructive (xem [SECURITY.vi.md](../SECURITY.vi.md)).

### ADR-2: HTTP/1.0 client tự viết trên unix socket

- **Bối cảnh:** `URLSession` của Foundation không hỗ trợ unix socket; dùng docker CLI cho mọi thao tác thì chậm và phụ thuộc Docker context.
- **Quyết định:** `DockerClient` được viết trực tiếp trên BSD socket, dùng HTTP/1.0 (đọc đến EOF), percent-encode path và query, có `SocketHandle` để huỷ.
- **Hệ quả:** hầu hết tính năng không cần docker CLI; stream multiplexed (`MultiplexedStreamParser`, `LogDemuxer`) và lỗi HTTP phải tự xử lý. Compose vẫn dùng docker CLI vì logic Compose nằm trong CLI.

### ADR-3: Không có dependency ngoài

- **Quyết định:** chỉ dùng framework của Apple (SwiftUI, Charts, AppKit, Foundation, Observation, CryptoKit, ServiceManagement, UserNotifications).
- **Hệ quả:** build tái lập được và bề mặt supply chain nhỏ; đổi lại, HTTP client, một parser YAML tối giản cho `colima.yaml` và phần xử lý tar header phải tự viết.

### ADR-4: Diagnostics là hàm thuần, chỉ đọc

- **Quyết định:** tách phần thu thập I/O (`DiagnosticsModel`) khỏi phần kiểm tra (hàm thuần trong `Diagnostics.swift`); không bao giờ tự động sửa cấu hình.
- **Hệ quả:** test được bằng fixture; người dùng giữ quyền quyết định mọi thay đổi.

### ADR-5: Proxy domain local dùng host network bên trong VM

- **Bối cảnh:** proxy cần tới được container trên nhiều bridge network. Cho proxy join vào network của một project sẽ làm `docker compose down` lỗi "network has active endpoints".
- **Quyết định:** container Caddy dùng `network_mode: host` bên trong VM, chỉ bind `127.0.0.1`, và dùng IP container làm upstream; không sửa DNS (dùng `*.localhost`).
- **Hệ quả:** network của người dùng không bị đụng tới; cấu hình phải được áp dụng lại khi IP container đổi (gắn với event `start`); port của proxy có thể trùng với port mà container khác trong VM publish.

### ADR-6: Chỉ dùng công cụ ngoài khi đã được cài sẵn

- **Quyết định:** quét CVE dùng `trivy` / `docker scout` có sẵn trên máy; app không tải hay cài gì.
- **Hệ quả:** giữ được ADR-3 (không dependency); output phụ thuộc phiên bản công cụ, nên parser decode một cách dễ dãi.

## 10. Nợ kỹ thuật và giới hạn

| Vấn đề | Ảnh hưởng | Hướng xử lý |
|---|---|---|
| Socket chỉ được resolve khi kết nối | Endpoint đổi lúc runtime thì phải kết nối lại | Đã tự kết nối lại khi stream events bị ngắt |
| Bản địa hoá (G18) đã implement: literal trong code là key tiếng Anh, bản dịch nằm trong `Resources/{en,vi}.lproj/Localizable.strings`, truy cập qua `String(localized:)` | Chuỗi mới phải thêm vào cả hai file `.lproj`; key chưa dịch sẽ fallback về tiếng Anh | `scripts/check-strings.sh` kiểm độ phủ key; `LocalizationTests` |
| UI test (XCUITest) chỉ phủ xác nhận destructive và che secret trên fixture, cần Xcode + quyền Accessibility để chạy | Chưa chạy trong CI; các luồng khác vẫn kiểm tay | `scripts/ui-tests.sh` trước mỗi lần phát hành; checklist trong [TESTING.vi.md](TESTING.vi.md) |
| Integration test (backup / restore database, Compose, proxy, Elasticsearch, vòng đời VM) cần VM Colima thật | Độ phủ trên máy thật phụ thuộc vào việc có người chạy; CI chỉ chạy unit test | Chạy lại `COLIMAX_INTEGRATION_ES=1 COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration` và checklist kiểm tay trong [TESTING.vi.md](TESTING.vi.md) trước mỗi lần phát hành |
