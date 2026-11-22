[English](FEATURES.md) · Tiếng Việt

# ColimaX — Trạng thái tính năng

> Đây là bản dịch tiếng Việt. Nguồn sự thật duy nhất là [FEATURES.md](FEATURES.md) (tiếng Anh); khi hai bản lệch nhau thì theo bản tiếng Anh.
>
> **Mọi agent (Claude Code, Codex, Cursor…) và người phát triển: đọc file này trước khi làm việc. Cập nhật ngay khi trạng thái đổi.**
> Không implement tính năng đã `Implemented` / `Verified` / `In Progress` mà không đọc code hiện có. Muốn làm lại thì ghi lý do vào cột Ghi chú.

## Quy ước trạng thái

| Trạng thái | Nghĩa | Điều kiện bắt buộc |
|---|---|---|
| `Planned` | Đã chốt sẽ làm, chưa có code | Có ID + ưu tiên |
| `In Progress` | Đang có người làm | Ghi **ai/agent**. Trước khi nhận một mục có vẻ bị bỏ dở, kiểm code và lịch sử git |
| `Implemented` | Code đã vào source, build sạch, có unit test (nếu test được) | Build 0 warning + test PASS |
| `Verified` | Đã chạy thật end-to-end trên Colima/Docker thật (integration test hoặc thao tác tay) | Ghi cách verify (tên test / lệnh) |
| `Verified (service layer)` | Tầng service đã chạy thật qua integration test, UI chưa kiểm end-to-end | Như `Verified`; ghi rõ phần chưa kiểm |
| `Blocked` | Không làm tiếp được | Ghi lý do + cần gì để gỡ |

Quy tắc:
- `FEATURES.md` (tiếng Anh) là nguồn sự thật; `FEATURES.vi.md` là bản dịch và phải được cập nhật trong cùng một thay đổi.
- Một tính năng chỉ có **một** dòng. Đổi trạng thái thì sửa tại chỗ, không thêm dòng mới.
- Bảng chỉ mô tả trạng thái hiện tại. Không ghi việc gì làm khi nào; lịch sử đó nằm trong git và [CHANGELOG.vi.md](../CHANGELOG.vi.md).
- Cột **Code** ghi file/type chính để agent khác tìm được, tránh viết trùng.
- Ưu tiên: `Core` là chức năng nền của sản phẩm; P0–P3 theo [AUDIT.vi.md](AUDIT.vi.md) (`G…`: gap ID, `R…`: rủi ro ID).
- Cột **Release** ghi phiên bản đầu tiên chứa tính năng; `—` nếu chưa nằm trong bản phát hành nào.
- Mục `Implemented` không có integration test trong Ghi chú thì chưa được chạy end-to-end. Cách chạy từng loại test: [TESTING.vi.md](TESTING.vi.md).

## Runtime

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C1 | Dashboard: trạng thái VM, CPU/RAM/Disk trong VM, Docker info, disk usage | Core | Implemented | 1.0.0 | `DashboardView`, `ColimaService.vmUsage`, `VMUsage` | Lấy mẫu mỗi 15 s khi đang hiển thị, tạm dừng khi cửa sổ thu nhỏ / ẩn / bị che (`WindowVisibility`). Ba thẻ dùng layout không lazy 3 / 2 + 1 / 1 cột (`overviewCards`); `LazyVGrid` adaptive từng treo main thread trong vòng layout vô hạn khi thẻ Docker đang hiện spinner. Unit: ColimaModelTests.testVMUsageParse |
| C7 | Runtime: start/stop/restart, tạo/xoá profile, đổi CPU/RAM/Disk/arch/runtime/VM type/mount/Rosetta/k3s/nested virtualization | Core | Verified (service layer) | 1.0.0 | `RuntimeSettingsView`, `ColimaService`, `RuntimeConfig`, `RuntimeModel.applyRuntimeConfig` | Thu nhỏ disk = xoá VM + dữ liệu rồi tạo lại (toggle riêng, xác nhận bằng cách gõ tên profile). Integration: VMProfileIntegrationTests (`COLIMAX_INTEGRATION_VM=1`). Unit: ColimaModelTests (tên profile, parseConfig) |
| C11 | Cập nhật realtime: Docker `/events` + kqueue `_lima` + poll dự phòng 30 s | Core | Implemented | 1.0.0 | `AppStore.connectDocker/reload`, `DirectoryWatcher` | |
| G2 | Resolve Docker endpoint từ `colima status --json` (`docker_socket`), fallback socket mặc định (R5) | P0 | Verified | 1.0.0 | `ColimaStatus`, `ColimaService.status/resolveDockerSocket`, `AppStore.resolveEndpoint` | Integration: resolve endpoint + ping trong setUp của IntegrationTests. Unit: ColimaModelTests |

## Containers

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C2 | Containers: list, start/stop/restart/pause/rm, logs stream, inspect, exec, mở Terminal | Core | Implemented | 1.0.0 | `ContainersView`, `LogsPane`, `DockerAPI.swift`, `TerminalLauncher` | Listing + API: integration testInfoAndListing |
| G6 | Container details: restart count, OOMKilled, exit code, health, resource limits, env (che secret), mounts, IP | P1 | Verified (service layer) | 1.0.0 | `ContainerDetails`, `EnvVar`, `ContainerDetailsPane`, icon health ở cột Status | Integration: testContainerDetailsExecAndPlatform (decode, exec). Unit: ContainerDetailsTests |
| G7 | Export log container ra file | P1 | Implemented | 1.0.0 | `LogsPane.export`, `LogExport`, `AtomicFile` | File log quyền 0600. Unit: BackupTests.testLogExportPermissionsAfterOverwrite |

## Compose

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C6 | Compose: nhận diện qua label, up/down/start/stop/restart/pull | Core | Implemented | 1.0.0 | `ComposeView`, `ComposeModel`, `ComposeService`, `ComposeProject` | Unit: StoreDerivedTests.testComposeProjectsFromLabels, StoreTests |
| G15 | Compose: phát hiện file trong thư mục + `.env`, validate, xem config, logs, restart/rebuild từng service | P1 | Verified (service layer) | 1.0.0 | `ComposeDiscovery`, `ComposeService.ServiceCommand/logs/config/validate`, `ComposeLogsSheet` | Không tự chạy project khi phát hiện file. Integration: testComposeLifecycle (validate, services, config, up, restart service, logs, down, file lỗi). Unit: ComposeTests |

## Images

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C3 | Images: list, pull (có tiến độ), rm, prune, inspect | Core | Verified (service layer) | 1.0.0 | `ImagesView`, `ImagesModel` | Integration: testInfoAndListing, testPullImageReportsProgress. Unit: ImageReferenceTests |
| G11 | Apple Silicon: kiến trúc image, cảnh báo giả lập amd64 | P1 | Verified (service layer) | 1.0.0 | `ImagePlatform`, `HostPlatform`, `ImageArchDiagnostics`, cột Arch (`ImagesView`) | Integration: testContainerDetailsExecAndPlatform (image platform arm64). Unit: DiagnosticsTests.testImageArchWarnings |
| G24 | Quét lỗ hổng image (Trivy / Docker Scout) | P3 | Verified (service layer) | 1.0.0 | `ScannerTool`, `VulnerabilityScanner` (VulnerabilityScanner.swift), `VulnerabilityScanSheet`, nút Scan (ImagesView) | Chỉ dùng Trivy / Docker Scout nếu đã cài; không bao giờ tự cài. Parse Trivy JSON và SARIF. Integration: testTrivyScanParsesRealOutput (skip nếu chưa cài trivy). Unit: ScannerTests (fixture) |

## Volumes & Backup

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C4 | Volumes: list, create, rm, prune, inspect, backup/restore tar | Core | Verified (service layer) | 1.0.0 | `VolumesView`, `VolumesModel`, `VolumeBackup` (BackupService.swift) | Integration: testInfoAndListing, testVolumeAndNetworkLifecycleWithScopedPrune, testCleanupStaleHelpersOnlyRemovesTestHelpers |
| G3 | Backup an toàn: ghi file tạm + rename, không nuốt lỗi ghi (R4) | P0 | Verified | 1.0.0 | `DockerClient.receiveToFile`, `AtomicFile` | Integration: testVolumeBackupVerifyRestoreRoundTrip (tải xuống atomic). Unit: DockerClientTests.testFailedDownloadKeepsExistingFileAndLeavesNoPartial |
| G8 | Manifest backup + SHA-256 + verify trước khi restore | P1 | Verified | 1.0.0 | `BackupManifest`, `BackupVerifier`, `TarInspector`, `VolumeBackup` | Integration: testVolumeBackupVerifyRestoreRoundTrip (backup → verify manifest → restore). Unit: BackupTests |
| G9 | Backup logic database: MySQL/MariaDB, PostgreSQL, Redis/Valkey | P1 | Verified (service layer) | 1.0.0 | `DatabaseEngine`, `DatabaseBackup`, `DockerClient.execToFile` | PostgreSQL dùng `pg_dumpall --clean --if-exists` để dump restore được. Integration: test{MySQL,MariaDB,Postgres}BackupRestoreRoundTrip (MySQL 8.4 / MariaDB 11 / PostgreSQL 16), Redis. Unit: BackupTests |
| G19 | Lịch backup + retention | P2 | Verified (service layer) | 1.0.0 | `BackupSchedule`, `BackupRetention`, `ScheduledBackupRunner` (BackupSchedule.swift), `BackupScheduler`, `BackupsView` | Timer trong app (kiểm mỗi phút), chạy bù lần lỡ khi mở app, thử lại sau 15 phút nếu lỗi. Retention chỉ xoá file khớp mẫu tên + manifest khớp nguồn. Container database được khớp theo tên. Integration: testScheduledBackupRunNow (`ScheduledBackupRunner`). Unit: ScheduleTests |
| G21 | Restore dump database | P2 | Verified (service layer) | 1.0.0 | `DatabaseRestore`, `TarWriter`, `DockerClient.uploadAsTar`, `Confirm.typed`, menu "Restore …" (ContainersView) | Verify manifest + loại dump + độ trọn vẹn của dump trước khi đụng tới Docker; xác nhận bằng cách gõ tên container. SQL: copy file vào /tmp của container qua archive API, client database đọc file, rồi xoá file. Redis: stop → thay RDB → start (từ chối khi bật AOF). Integration: round-trip MySQL 8.4 / MariaDB 11 / PostgreSQL 16 / Redis. Unit: RestoreTests |
| G25 | Snapshot Elasticsearch | P3 | Verified (service layer) | 1.0.0 | `ElasticsearchSnapshot`, `ElasticsearchSnapshotSheet`, menu "Snapshots…" (ContainersView) | Elasticsearch / OpenSearch. REST qua curl trong container, tham số truyền dạng argv. Cần `path.repo`. Tạo / liệt kê / xoá / restore (mặc định thành `restored-*`; ghi đè phải gõ tên) / export repository thành `.tar` + manifest. Integration: testElasticsearchSnapshotRoundTrip (`COLIMAX_INTEGRATION_ES=1`, Elasticsearch 8.15.3). Unit: ElasticsearchTests |

## Networks

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C5 | Networks: list, create, rm, prune, inspect | Core | Verified (service layer) | 1.0.0 | `NetworksView`, `NetworksModel` | Integration: testInfoAndListing, testVolumeAndNetworkLifecycleWithScopedPrune |
| G14 | Connect / disconnect container vào/ra network | P1 | Verified | 1.0.0 | `DockerClient.connect/disconnect` (DockerAPI.swift), `NetworkMembersSheet` | Integration: testNetworkConnectDisconnect |
| G22 | Topology network, đồ thị phụ thuộc compose | P3 | Implemented | 1.0.0 | `NetworkTopology`, `ComposeDependencyGraph` (Topology.swift), `TopologyView`, `ComposeService.dependencyGraph` | Chỉ đọc. Đồ thị network ↔ container (hover để làm nổi bật), đồ thị depends_on theo tầng, báo vòng lặp. Unit: TopologyTests |
| G23 | Domain local, reverse proxy (Caddy/Traefik), HTTPS local | P3 | Verified (service layer) | 1.0.0 | `LocalProxy`, `ProxyRoute`, `ProxySettings`, `TarReader` (LocalProxy.swift), `ProxyStore` (`store.proxy`), `LocalDomainsView` | Caddy `caddy:2-alpine`, `network_mode: host` trong VM, chỉ bind 127.0.0.1, upstream = IP container (không join network của người dùng). `*.localhost`, không sửa DNS. HTTPS qua `local_certs`; tin cậy CA là nút tuỳ chọn (`security add-trusted-cert`, login keychain). Caddy admin qua unix socket + thử lại reload. Integration: testLocalProxyRoutesByHost (trong VM + từ Mac qua 127.0.0.1, root CA), testLocalProxyFollowsTargetRestart, testComposeDownWithProxyRouteSucceeds. Chưa kiểm end-to-end: tin cậy CA. Unit: ProxyTests |

## Monitoring & Storage

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C8 | Monitoring: CPU/RAM/Net/Block I/O theo container (streaming) | Core | Verified (service layer) | 1.0.0 | `MonitoringView`, `MonitorStore` | Lịch sử 90 mẫu trong bộ nhớ. Integration: testStatsOneShotAndMetricsHistory |
| G13 | Storage: volume mồ côi, image không dùng, build cache, dọn dẹp có xác nhận | P1 | Verified (service layer) | 1.0.0 | `StorageReport`, `StorageView`, `StorageModel`, `DockerClient.pruneBuildCache/pruneStoppedContainers` | Integration: testStorageReportWithRealDiskUsage. Unit: StorageReportTests |
| G20 | Cảnh báo ngưỡng tài nguyên, lưu lịch sử | P2 | Verified (service layer) | 1.0.0 | `ResourceAlerts.swift` (`AlertEvaluator`, `MetricsHistory`), `ResourceWatcher` (`store.resources`), `MetricsHistorySheet` (MonitoringView), Preferences | Lấy mẫu nền mỗi phút (`/stats?stream=0`), lưu 3 ngày JSONL trong Application Support, cảnh báo khi CPU container (% của VM) / RAM (% của limit) vượt ngưỡng liên tục N phút + disk VM, hysteresis 90%. Integration: testStatsOneShotAndMetricsHistory. Unit: AlertTests |

## Diagnostics & Security

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| G10 | Diagnostics: CLI, ping endpoint, Docker context, lệch cấu hình, VZ/virtiofs/Rosetta, gợi ý tài nguyên | P1 | Implemented | 1.0.0 | `RuntimeDiagnostics`, `DockerContextReader`, `SocketPermissions`, `DiagnosticsModel`, `DiagnosticsView` | Unit: DiagnosticsTests |
| G12 | Security audit: privileged, capability nguy hiểm, mount docker.sock, host namespace, bind 0.0.0.0, secret trong env, quyền socket | P1 | Verified (service layer) | 1.0.0 | `SecurityAudit` | Chỉ đọc. Integration: testSecurityAuditOnRealContainer. Unit: DiagnosticsTests.testSecurityAuditFindingsAndNoSecretLeak |
| G16 | Phát hiện xung đột port | P1 | Verified (service layer) | 1.0.0 | `PortDiagnostics`, `PortProbe` | Integration: testPortHeldByHostProcessIsReported. Unit: DiagnosticsTests.testPortConflicts, testPortProbeDetectsListeningSocket |

## App / UX

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| C9 | Preferences: theme Light/Dark/System, icon Dock, login item, tự start VM, thông báo | Core | Implemented | 1.0.0 | `PreferencesView`, `AppSettings`, `LaunchAtLogin`, `Notifier` | Login item và thông báo cần bundle `.app` |
| C10 | Menu bar: trạng thái, chọn profile, start/stop/restart, thao tác nhanh container | Core | Implemented | 1.0.0 | `MenuContentView`, `MenuBarIcon` | Stop / Restart hỏi xác nhận khi còn container đang chạy (`VMControl`, cả toolbar + Dashboard). Icon: glyph template monogram CX; chấm = đang chạy, vòng = đang có thao tác, mờ = đã dừng |
| G4 | Huỷ thao tác dài + trạng thái "Cancelled"; process bị kill bởi signal không tính là thành công (R6) | P0 | Implemented | 1.0.0 | `OperationCenter.launch/cancelOperation/runOperation`, `OperationPanel`, `AppDelegate.applicationShouldTerminate` | Thoát app khi đang có thao tác thì hỏi trước rồi huỷ thao tác (⌘Q / menu bar / Dock / Restart Now); thoát app không bao giờ dừng VM hay container. Unit: OperationTests |
| G17 | Phím tắt ⌘1…⌘9 chuyển màn hình | P1 | Implemented | 1.0.0 | `Screen.shortcutOrder` (MainWindow.swift), menu "Go" (ColimaXApp.swift) | Unit: OperationTests.testShortcutOrderHasNineUniqueScreens |
| G18 | Bản địa hoá (tiếng Anh + tiếng Việt) | P2 | Implemented | 1.0.0 | `Resources/{en,vi}.lproj/Localizable.strings`, `AppLanguage` + picker (AppSettings / PreferencesView), `Format.digits`, `scripts/check-strings.sh`, `scripts/build-app.sh` (copy .lproj, `CFBundleLocalizations`) | Literal trong code là tiếng Anh (key); bản dịch vi khoảng 700 key. Mặc định theo ngôn ngữ hệ thống, chọn được trong Preferences (`AppleLanguages`, cần khởi động lại). Port / exit code hiển thị không có dấu phân cách hàng nghìn (`Format.digits`). Unit: LocalizationTests |
| G26 | Onboarding: kiểm Homebrew / colima / docker CLI / compose plugin, cài qua `brew install` có xác nhận, cấu hình compose plugin, start profile đầu tiên | P1 | Implemented | 1.0.0 | `PrerequisiteReport`, `Prerequisites` (Features/Setup/Prerequisites.swift), `SetupSheet` (Features/Setup/SetupView.swift), `SetupModel.check/install`, menu "Setup Assistant…" | Tự mở khi thiếu công cụ (tắt được). Không cài Homebrew (cần sudo + tải script): hiện lệnh + nút Copy. `brew install` chỉ nhận colima / docker / docker-compose, chạy `Process` với mảng tham số, có log + huỷ trong sheet. Compose plugin: thêm `cliPluginsExtraDirs` vào `~/.docker/config.json` (hoặc `$DOCKER_CONFIG`), giữ các key khác, backup sang `config.json.colimax-backup`, ghi với quyền 0600. UI: SetupUITests (installer giả). Chưa chạy trên máy sạch. Unit: SetupTests |

## Engineering / Quality

| ID | Tính năng | Ưu tiên | Trạng thái | Release | Code | Ghi chú |
|---|---|---|---|---|---|---|
| G1 | I/O blocking nằm ngoài cooperative pool; timeout + huỷ cho process & socket (R1–R3) | P0 | Implemented | 1.0.0 | `BlockingIO`, `ProcessExecution` (Shell.swift), `SocketHandle`, `DockerClient.connection` | Integration: testCancelledLogStreamClosesQuickly. Unit: ShellTests (timeout, cancel, đồng thời, output lớn) |
| G5 | Hiệu năng: log viewer append tăng dần, cache formatter, `which` tra theo PATH (R7–R9) | P0 | Implemented | 1.0.0 | `CodeTextView` (append), `Format` (cache), `Shell.which` (PATH) | Unit: ShellTests.testWhichRejectsPaths |
| T1 | Target test XCTest (unit + integration có điều kiện) | Core | Implemented | 1.0.0 | `Tests/ColimaXTests`, `Tests/Runner/main.swift`, `scripts/run-tests.sh`, testTarget `ColimaXTests` trong `Package.swift` | Integration test chỉ chạy khi có `COLIMAX_INTEGRATION=1` (`--integration` tự đặt); test Elasticsearch và VM cần thêm `COLIMAX_INTEGRATION_ES=1` / `COLIMAX_INTEGRATION_VM=1` |
| T2 | GitHub Actions CI: build 0 warning (`WARNINGS_AS_ERRORS=1`) + unit test + đóng gói | Core | Implemented | 1.0.0 | `.github/workflows/ci.yml`, `scripts/dev-build.sh` | Chưa chạy trên GitHub (chưa có repository) |
| T3 | Pipeline release: ký Developer ID (có timestamp), notarize + staple app & DMG, SHA-256, GitHub Release nháp | Core | Implemented | 1.0.0 | `scripts/release.sh`, `scripts/notarize.sh`, `scripts/make-dmg.sh`, `.github/workflows/release.yml`, [RELEASE.vi.md](RELEASE.vi.md) | `build-app.sh` + `make-dmg.sh` đã chạy thật (chữ ký ad-hoc). Ký Developer ID / notarize / workflow chưa chạy (cần certificate + repository). `hdiutil create` báo deprecated trên macOS mới; chuyển sang `diskutil image create` khi cần |
| T4 | Icon app (`Resources/AppIcon.icns`, `CFBundleIconFile`) | Core | Implemented | 1.0.0 | `scripts/make-icon.swift`, `scripts/make-icon.sh`, `scripts/build-app.sh` | Vẽ bằng CoreGraphics, monogram CX (dùng chung cho glyph menu bar `MenuBarIcon` và glyph trong `site/`); có thể thay bằng icon do designer làm |
| T5 | Template issue / PR, kênh báo lỗ hổng riêng tư | Core | Implemented | 1.0.0 | `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md`, `SECURITY.md` | Private vulnerability reporting được bật khi tạo repository GitHub |
| T6 | Protocol service + fake trong bộ nhớ: `DockerEngine`, `ColimaControlling`, inject qua `AppServices` | Core | Implemented | 1.0.0 | `DockerEngine` (Core/Docker), `ColimaControlling` + `LiveColima` (Core/Colima), `AppServices` (App), `FakeDocker` / `FakeColima` (Testing/Fakes.swift, `-D COLIMAX_UI_TESTING`) | Store và mọi service, kể cả truyền file / archive (backup, restore, proxy, Elasticsearch), chạy được không cần VM. Unit: StoreTests, TransferFakeTests |
| T7 | Tách `AppStore`: `OperationCenter` + model theo màn hình | Core | Implemented | 1.0.0 | `OperationCenter`, `RuntimeModel`, `SetupModel`, `ContainersModel`, `ComposeModel`, `ImagesModel`, `VolumesModel`, `NetworksModel`, `StorageModel`; `DockerContext` / `ProfileContext` | `AppStore` giữ profile, dữ liệu Docker, kết nối / events và điều hướng. Cách thêm màn hình: [ARCHITECTURE.vi.md](ARCHITECTURE.vi.md) mục 8. Unit: StoreTests, OperationTests |
| T8 | Host protocol hẹp thay cho `weak store: AppStore` | Core | Implemented | 1.0.0 | `BackupSchedulerHost`, `ResourceWatcherHost`, `ProxyHost` (AppServices.swift) | `BackupScheduler`, `ResourceWatcher`, `ProxyStore` không biết `AppStore`. Unit: StoreTests (host giả) |
| T9 | UI test (XCUITest): xác nhận thao tác phá huỷ, che secret | Core | Verified | 1.0.0 | `UITests/ColimaXUITests.xcodeproj`, `UITests/ColimaXUITests/*`, `scripts/ui-tests.sh`, `UITestFixtures` | Điều khiển `build/ColimaX-UITest.app` (`-D COLIMAX_UI_TESTING`, bundle ID `dev.colimax.ColimaX.uitest`) với `COLIMAX_UI_TEST_FIXTURES=1`: xoá container (Cancel giữ lại / xác nhận chỉ xoá đúng nó), stop VM khi còn container chạy hỏi trước, xoá profile, xoá / prune volume, prune toàn bộ image, compose down (chỉ Cancel) hỏi trước, `POSTGRES_PASSWORD` bị che đến khi bấm Show Secrets. Verified: `scripts/ui-tests.sh` trên máy dev. Job CI `ui-tests` chưa chạy trên GitHub (continue-on-error) |
| T10 | Chuyển checklist thủ công sang test tự động: unit test cho logic, XCUITest với kịch bản fixture cho phần nối UI | Core | Verified | 1.0.0 | `Tests/ColimaXTests/ChecklistTests.swift`, `UITests/ColimaXUITests/{ChecklistUITests,SetupUITests}.swift`, `UITestScenario` / `FakePrerequisites` (Testing/Fakes.swift), `AppServices.notify` / `scannerTools`, `RuntimeChange`, `DiagnosticItem.visible`, `StorageReport.unusedVolumeNames`, `VMControl` confirmer, `FilePanels.open` (`COLIMAX_UI_TEST_OPEN_FILE`) | Verified: `scripts/ui-tests.sh` trên máy dev (ChecklistUITests, SetupUITests); mục đã tự động hoá được đánh dấu trong [TESTING.vi.md](TESTING.vi.md). Vẫn kiểm tay: menu bar, Dock, gửi thông báo, login item, tin cậy CA, Terminal / trình duyệt, biểu đồ / topology, hộp thoại lưu file, `brew install` thật trên Mac sạch |
| T11 | Trang giới thiệu trên GitHub Pages (tiếng Anh + tiếng Việt), sẵn sàng cho custom domain `colimax.dev` | Core | Implemented | 1.0.0 | `site/index.html`, `site/vi/index.html`, `site/style.css`, `site/copy.js`, `site/img/`, `.github/workflows/pages.yml`, `scripts/site-screenshots.sh`, `DemoFixtures` (Testing/DemoFixtures.swift) | HTML tĩnh, không có bước build, không tải tài nguyên ngoài (dùng font hệ thống). Hero dựng lại menu trên menu bar (`MenuContentView`). Ảnh chụp lấy từ kịch bản fixture `demo` (project giả, biểu đồ chuyển động), chụp bằng `scripts/site-screenshots.sh`. Unit: StoreTests.testDemoFixturesHaveMovingStatsAndRealisticData. Đã kiểm trên máy ở độ rộng desktop và điện thoại. Workflow Pages đã deploy lên `https://trongcong.github.io/colimax/`; các bước custom domain trong [RELEASE.vi.md](RELEASE.vi.md) mục 2.5 |

## Verify

Trạng thái của code hiện tại. Khi một lần chạy làm thay đổi kết quả, sửa dòng tương ứng; không ghi thêm lịch sử.

| Kiểm tra | Lệnh | Kết quả |
|---|---|---|
| Build | `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh` | 0 warning |
| Unit test | `scripts/run-tests.sh` | Pass hết; integration test skip khi không có VM |
| Integration test | `COLIMAX_INTEGRATION_ES=1 COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration` (profile Colima `default` đang chạy) | Pass hết, 0 skip; không sót container, volume hay network `dev.colimax.test` |
| UI test | `scripts/ui-tests.sh` (cần Xcode + quyền Accessibility) | Pass hết (`ColimaXUITests`, `ChecklistUITests`, `SetupUITests`) |
| Bản dịch | `scripts/check-strings.sh` | OK |
| Đóng gói | `scripts/build-app.sh && scripts/make-dmg.sh` | Build release, chữ ký ad-hoc hợp lệ, DMG + SHA-256 |
| Kiểm tay UI | Checklist trong [TESTING.vi.md](TESTING.vi.md) | Đã làm cho 1.0.0; mục đã có UI test được đánh dấu ở đó |
| Chưa chạy | Một lần CI xanh trên GitHub, ký Developer ID + notarize, Setup Assistant trên Mac sạch | — |
