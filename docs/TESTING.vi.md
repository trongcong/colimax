# Kiểm thử

[English](TESTING.md) · Tiếng Việt

Kết quả hiện tại của từng tầng test nằm trong [FEATURES.vi.md](FEATURES.vi.md#verify). Tài liệu này giải thích cách chạy và phạm vi của chúng.

## Chiến lược

| Tầng | Cách test | Ghi chú |
|---|---|---|
| Logic thuần (parser, validator, Diagnostics, manifest, tar header, script dump) | Unit test với fixture | Phần lớn bộ test. Không cần Colima / Docker |
| Process và socket (`Shell`, `ProcessExecution`, `DockerClient`) | Unit test với process và socket local | Phủ timeout, huỷ, output lớn, thiếu socket |
| Thao tác chạy lâu (`OperationCenter.runOperation`) | Unit test với stream giả | Thành công, thất bại, huỷ |
| Store và model màn hình (`AppStore`, `RuntimeModel`, `ContainersModel`, …, host của `BackupScheduler` / `ResourceWatcher`) | Unit test với `FakeColima` / `FakeDocker` (`StoreTests`) | Reload, xoá lỗi, events, thao tác VM, khoá busy; không cần VM. `scripts/run-tests.sh` biên dịch với `-D COLIMAX_UI_TESTING` để có fake |
| Docker Engine API thật | Integration test có điều kiện | Chỉ chạy khi đặt cờ và VM phản hồi |
| VM / profile Colima thật | Integration test có điều kiện riêng (`COLIMAX_INTEGRATION_VM=1`) | Tạo một profile `colimax-test-*` nhỏ rồi xoá sau đó |
| Logic của checklist (xác nhận khi đổi runtime, bộ lọc Diagnostics, chọn trong Storage, Setup Assistant, xác nhận stop VM, thông báo) | Unit test với fake (`ChecklistTests.swift`) | Các mục của checklist thủ công không cần UI |
| UI: xác nhận, form, sheet, phím tắt, các trạng thái của Setup Assistant, che secret | XCUITest với fixture và kịch bản fixture (`scripts/ui-tests.sh`, xem [UI test](#ui-test-xcuitest)) | Cần Xcode + quyền Accessibility. 31 test, khoảng 6,5 phút. Chưa chạy trong CI |
| Các luồng UI còn lại | Kiểm tra thủ công theo checklist bên dưới | Tích hợp hệ thống, hình ảnh, hộp thoại lưu file, VM thật |

## Chạy test

| Lệnh | Phạm vi | Ghi chú |
|---|---|---|
| `scripts/run-tests.sh` | Unit test | Build bằng `swiftc` (target `arm64-apple-macosx14.0`) với XCTest của Xcode, dùng runner tự viết trong `Tests/Runner/main.swift`. Không cần SwiftPM. Integration test tự skip |
| `scripts/run-tests.sh --integration` | Unit + integration | Đặt `COLIMAX_INTEGRATION=1`. Profile lấy từ `COLIMAX_PROFILE` (mặc định `default`). Cần VM Colima đang chạy với runtime docker |
| `swift test` | Unit (+ integration nếu đặt biến môi trường) | Qua SwiftPM, target `ColimaXTests` (`@testable import ColimaX`) |

Ví dụ:

```bash
COLIMAX_PROFILE=dev scripts/run-tests.sh --integration
COLIMAX_INTEGRATION_VM=1 scripts/run-tests.sh --integration   # adds the VM/profile lifecycle (a few minutes)
OUT_DIR="$TMPDIR/colimax-tests" scripts/run-tests.sh   # change the build directory (default $TMPDIR/colimax-tests)
```

`scripts/run-tests.sh` loại `ColimaXApp.swift` (`Sources/ColimaX/App/ColimaXApp.swift`, file chứa `@main`) khỏi build và trả exit code khác 0 nếu build lỗi hoặc có test lỗi. File tạm của test nằm dưới `$TMPDIR` (`TestSupport.tempRoot`).

Một số test tự skip khi môi trường không cho phép: `ComposeTests.testDiscoveryPriorityOverrideAndEnv` (không tạo được `.env`), `DiagnosticsTests.testPortProbeDetectsListeningSocket` (không bind được TCP).

## UI test (XCUITest)

`UITests/` chứa Xcode project `ColimaXUITests.xcodeproj` với một target UI-testing bundle duy nhất. Project không tự build app: `scripts/ui-tests.sh` build trước một bundle riêng, `build/ColimaX-UITest.app`, biên dịch với `-D COLIMAX_UI_TESTING` và bundle ID `dev.colimax.ColimaX.uitest` (UserDefaults riêng, không đụng tới cài đặt của app thật), rồi chạy `xcodebuild test`. Test khởi chạy bundle đó với `COLIMAX_UI_TEST_FIXTURES=1`, nên app dùng `UITestFixtures` (`FakeColima` + `FakeDocker`: profile `default` đang chạy, container `web`, `db` (compose project `shop`) và `worker`, volume `db-data`, image `nginx:latest`, `postgres:16` và image amd64 `legacy/app:1.0`, không có scanner lỗ hổng); không cần VM Colima hay Docker và không xoá gì thật.

Biến môi trường khởi chạy mà bản build UI test hiểu (`UITestApp.launch` đặt chúng):

| Biến | Tác dụng |
|---|---|
| `COLIMAX_UI_TEST_SCREEN` | Màn hình mở khi khởi động (raw value của `Screen`) |
| `COLIMAX_UI_TEST_SCENARIO` | Biến thể fixture (`UITestScenario`): `vm-stopped`, `slow-op` (thao tác VM không bao giờ xong cho tới khi bị huỷ), `no-brew`, `missing-tools`, `compose-plugin`, `no-profile`, `elasticsearch` (thêm một cluster không có `path.repo`), `demo` (khối lượng công việc giống thật để chụp ảnh cho trang giới thiệu, `DemoFixtures`) |
| `COLIMAX_UI_TEST_FOCUS` | Container demo được chọn sẵn ở màn hình Containers (`DemoFixtures.containerID`, ví dụ `db`) |
| `COLIMAX_UI_TEST_DETAIL_TAB` | Tab mở sẵn trong phần chi tiết container: `Info`, `Logs` (mặc định), `Inspect`, `Exec` |
| `COLIMAX_UI_TEST_OPEN_FILE` | File mà hộp thoại mở file trả về (`FilePanels.open`), ví dụ một dump để restore |
| `DOCKER_CONFIG` | Thư mục config của Docker CLI mà **Configure Plugin** ghi vào (một thư mục tạm trong test) |

Đã phủ:

- `ColimaXUITests` (8 test):
  - xác nhận destructive, mỗi test kiểm Cancel không đổi gì và, khi an toàn, xác nhận thì thao tác chạy đúng: xoá container, dừng VM khi có container đang chạy, xoá profile, xoá / prune volume, prune toàn bộ image không dùng, `docker compose down` (chỉ nhánh Cancel: xác nhận sẽ gọi compose CLI thật; tự skip khi chưa cài);
  - che secret: `POSTGRES_PASSWORD` của container `db` bị che cho tới khi bật "Show Secrets".
- `ChecklistUITests` (18 test): ⌘1…⌘9 / menu Go / ⌘,; trạng thái chờ khi VM đã dừng; huỷ thao tác dài; thoát khi đang có thao tác và khi không có; Runtime Settings (tên profile không hợp lệ, đổi CPU thì hỏi restart, đổi arch thì hỏi tạo lại, gõ tên xác nhận để thu nhỏ disk và công tắc unlock tự tắt lại); Copy KEY=VALUE bị ẩn khi đang che; restore database gõ tên xác nhận và lỗi preflight; nút Pull bị vô hiệu với reference không hợp lệ và cảnh báo Arch; quét lỗ hổng khi không có scanner; form tạo network và xác nhận xoá / prune; xác nhận rebuild service compose (chỉ nhánh Cancel); Elasticsearch không có `path.repo`; UI tiếng Việt.
- `SetupUITests` (5 test): đã cài đủ công cụ, không có Homebrew, thiếu công cụ (đúng lệnh `brew install`, cài giả, các dòng được làm mới), compose plugin chưa được nạp (ghi một `DOCKER_CONFIG` tạm), chưa có profile (Start Colima).

Điều kiện: có Xcode (không chỉ Command Line Tools); lần chạy đầu cho phép test runner trong System Settings → Privacy & Security → Accessibility (và Automation nếu được hỏi). Chạy trong phiên desktop đã đăng nhập; test sẽ điều khiển chuột và bàn phím.

```bash
scripts/ui-tests.sh            # build app UI test và chạy toàn bộ UI test
```

Bản release (`scripts/build-app.sh`) không bao giờ chứa fixture: chúng chỉ được biên dịch khi có `-D COLIMAX_UI_TESTING`.

## Integration test an toàn

`IntegrationTests.swift` chạy với Colima và Docker thật:

- Tự skip trừ khi đặt `COLIMAX_INTEGRATION=1` và `/_ping` của profile phản hồi.
- Resolve endpoint giống hệt app: `colima status --json`, fallback về socket mặc định.
- Mọi tài nguyên test tạo ra đều có tên với tiền tố `colimax-test-<id>` và mang label `dev.colimax.test`; `tearDown` xoá các container, network, volume và thư mục tạm mà nó đã tạo.
- Không bao giờ đụng tới container, volume hay network có sẵn của người dùng.
- Có thể pull các image sau nếu chưa có (image được giữ lại sau khi test): `busybox:latest`, `redis:7-alpine`, `mysql:8.4`, `mariadb:11`, `postgres:16-alpine`, `caddy:2-alpine`; lần chạy đầu mất vài phút để tải.
- `testComposeLifecycle` cần docker CLI + compose plugin (nếu không có thì skip). Project được đặt tên `colimax-test-<id>`, và `tearDown` chạy `compose down`.
- `testLocalProxyRoutesByHost` cần port 18080 / 18443 còn trống trên Mac (skip nếu đang bận); proxy và volume CA của test được đặt tên `colimax-test-*` và không bao giờ đụng tới `colimax-proxy` của người dùng.
- `testElasticsearchSnapshotRoundTrip` chỉ chạy khi đặt thêm `COLIMAX_INTEGRATION_ES=1` (image Elasticsearch khoảng 1 GB và cần khoảng 1 GB RAM trong VM).
- Container / volume / network / image của test mang label `dev.colimax.test=<prefix>`. Lệnh prune trong test luôn lọc đúng theo label này (`pruneVolumes(all:label:)`, `pruneNetworks(label:)`) và không bao giờ prune toàn cục.
- `testCleanupStaleHelpersOnlyRemovesTestHelpers` gọi `cleanupStaleHelpers(requiredLabel: "dev.colimax.test")`: helper thật của app (không có label test) không bị đụng tới.
- `testPullImageReportsProgress` pull `busybox:1.36`; image chỉ bị xoá nếu trước đó chưa có. `testStorageReportWithRealDiskUsage` tạo một image dangling bằng `commit` và xoá nó trong `tearDown`.
- `testLocalProxyFollowsTargetRestart` và `testComposeDownWithProxyRouteSucceeds` dùng port 18080 / 18443 giống test proxy ở trên (skip nếu đang bận); test compose cần docker CLI + compose plugin.
- `testTrivyScanParsesRealOutput` chỉ chạy khi có `trivy` trong PATH; lần dùng đầu Trivy tải cơ sở dữ liệu lỗ hổng (cần mạng; skip nếu tải thất bại).
- `VMProfileIntegrationTests` chỉ chạy khi đặt thêm `COLIMAX_INTEGRATION_VM=1`: nó tạo profile `colimax-test-<id>` (1 CPU, 1 GiB RAM, 12 GiB disk), và `tearDown` xoá profile kể cả khi test lỗi giữa chừng. Các profile khác không bị đụng tới.

| Test | Kiểm tra gì |
|---|---|
| `testInfoAndListing` | `/info`, liệt kê container / image / volume / network, `/system/df` |
| `testContainerDetailsExecAndPlatform` | Inspect (running, restart count, OOM, env nhạy cảm), exec với exit code riêng, kiến trúc image arm64 |
| `testNetworkConnectDisconnect` | Connect / disconnect container với network |
| `testVolumeBackupVerifyRestoreRoundTrip` | Backup → verify manifest → restore vào volume khác → đọc lại nội dung; helper đã được dọn |
| `testRedisLogicalBackup` | Dump Redis, header `REDIS`, manifest khớp |
| `testDatabaseBackupFailureLeavesNoFile` | Dump thất bại (không có `pg_dumpall`) → `dumpFailed`, không để lại file hay manifest |
| `testCancelledLogStreamClosesQuickly` | Huỷ một stream log follow kết thúc trong dưới 5 s |
| `testMySQLBackupRestoreRoundTrip`, `testMariaDBBackupRestoreRoundTrip`, `testPostgresBackupRestoreRoundTrip` | Tạo DB + bảng → dump (manifest khớp) → drop DB → restore (G21) → dữ liệu trở lại, không có cảnh báo, file tạm trong container đã bị xoá |
| `testRedisRestoreRoundTrip` | Dump RDB → `flushall` → restore (stop / thay RDB / start) → key trở lại |
| `testComposeLifecycle` | validate, services, config, up, restart service, logs, down; file hỏng → validate báo lỗi |
| `testLocalProxyRoutesByHost` | Proxy Caddy (host network) route `web.localhost` → một container trong VM, và từ Mac qua 127.0.0.1; route tới container không tồn tại bị bỏ qua; proxy không join network của người dùng; HTTPS sinh ra root CA |
| `testElasticsearchSnapshotRoundTrip` | Đăng ký repository, tạo snapshot, restore thành `restored-*` và ở chế độ ghi đè, export `.tar` + manifest, xoá snapshot |
| `testSecurityAuditOnRealContainer` | Container privileged + bind `0.0.0.0` + `APP_TOKEN`: `SecurityAudit` báo privileged (critical), port (info / warning khi VM có IP riêng), và tên biến secret; giá trị secret không xuất hiện trong bất kỳ kết quả nào |
| `testPortHeldByHostProcessIsReported` | Một socket đang listen thật trên Mac + một container đã dừng khai báo cùng port: `PortDiagnostics` báo "process on the Mac"; nhả port thì cảnh báo biến mất |
| `testStorageReportWithRealDiskUsage` | `/system/df` thật: volume mồ côi được liệt kê, volume đang mount thì không; image `commit` không tag là dangling; container đã exit xuất hiện trong danh sách đã dừng |
| `testVolumeAndNetworkLifecycleWithScopedPrune` | Tạo / xoá volume có label; network có subnet / gateway; prune volume / network theo label chỉ xoá tài nguyên test không dùng |
| `testPullImageReportsProgress` | Pull có stream tiến độ, image tồn tại sau khi pull; reference không hợp lệ bị chặn; pull image không tồn tại thì báo lỗi |
| `testScheduledBackupRunNow` | `ScheduledBackupRunner` (lõi của "Run Now"): 3 lần backup volume với keep = 2 để lại đúng 2 bản mới nhất, file không liên quan không bị đụng; Redis theo tên container tạo ra `.rdb` + manifest; container không tồn tại → `containerNotRunning` |
| `testStatsOneShotAndMetricsHistory` | `client.stats` một lần: memory > 0, CPU trong khoảng hợp lệ; ghi / đọc `MetricsHistory` |
| `testCleanupStaleHelpersOnlyRemovesTestHelpers` | Chỉ xoá helper `created` mang label test; container thường và helper đang chạy được giữ lại |
| `testLocalProxyFollowsTargetRestart` | Container đích restart sau khi IP cũ đã bị chiếm → cấu hình được áp dụng lại → proxy vẫn route được |
| `testComposeDownWithProxyRouteSucceeds` | Proxy route tới một compose service; `compose down` thành công, network của project bị xoá, proxy vẫn chạy; route tới container đã biến mất bị bỏ qua |
| `testTrivyScanParsesRealOutput` | Trivy thật quét `busybox:latest`; `parseTrivy` đọc được mọi lỗ hổng trong output thật; `VulnerabilityScanner.scan` hoạt động |
| `VMProfileIntegrationTests.testProfileLifecycleAndDiskShrink` | Profile `colimax-test-*`: start (Docker phản hồi) → stop → thu nhỏ disk 12 → 10 GiB bằng cách xoá VM + dữ liệu rồi tạo lại → delete; các profile khác không đổi |

## Ma trận unit test

File test nằm trong `Tests/ColimaXTests/`.

| File | Test class (số test) | Phạm vi phủ |
|---|---|---|
| `ShellTests.swift` | `ShellTests` (14) | `Shell.run` / `Shell.stream` / `ProcessExecution`, `which`, timeout, huỷ, concurrency, output lớn, `ColimaLog` |
| `DockerClientTests.swift` | `DockerClientTests` (12) | Request line + percent-encoding, `dechunk`, ánh xạ lỗi HTTP, lỗi socket, truyền file an toàn, `MultiplexedStreamParser`, `LogDemuxer`, `LineSplitter`, `FileHasher`, filter prune theo label |
| `ModelTests.swift` | `ColimaModelTests` (8), `ContainerDetailsTests` (5), `ImageReferenceTests` (3) | `ColimaStatus` + fallback socket, `unixPath`, tên profile, `parseConfig`, `VMUsage.parse`, `Format.date`; decode `ContainerDetails`, `EnvVar` nhạy cảm, health, `ImagePlatform`; `ImageReference.isValid` (PullSheet, scanner) |
| `BackupTests.swift` | `BackupTests` (16) | Manifest + verify, tar header, restore có kiểm tra trước, nhận diện database, script dump, validate dump, chọn helper cũ, quyền 0600 của log đã export kể cả khi ghi đè |
| `DiagnosticsTests.swift` | `DiagnosticsTests` (10), `StorageReportTests` (2) | Kiểm tra runtime, lệch cấu hình, tài nguyên / ảo hoá, quyền socket, security audit, xung đột port, `PortProbe`, Docker context, kiến trúc image; `StorageReport` |
| `ComposeAndStoreTests.swift` | `ComposeTests` (7), `OperationTests` (4), `StoreDerivedTests` (1) | `ComposeDiscovery`, tên service / project, tham số dạng mảng; `OperationCenter.runOperation` (thành công / thất bại / huỷ), `Screen.shortcutOrder`; `ComposeModel.projects` từ label |
| `RestoreTests.swift` | `RestoreTests` (9) | `TarWriter` (checksum, kích thước, tên không an toàn), cấu hình Redis, lọc cảnh báo psql, script restore, preflight (khớp / sai engine / dump bị cắt cụt) |
| `ScheduleTests.swift` | `ScheduleTests` (7) | Đến hạn / thử lại sau khi lỗi, tên file, tính hợp lệ, Codable, giới hạn giữ lại không đụng file không liên quan, giới hạn giữ lại với các manifest trùng timestamp |
| `AlertTests.swift` | `AlertTests` (5) | Vượt ngưỡng kéo dài, không spam, hysteresis, memory cần có limit, disk, `MetricsHistory` append / load / prune |
| `ScannerTests.swift` | `ScannerTests` (7) | Parse Trivy JSON và SARIF, sắp xếp / loại trùng, ID duy nhất, validate reference, điểm CVSS |
| `ElasticsearchTests.swift` | `ElasticsearchTests` (7) | Nhận diện image, tên snapshot, parse response / `path.repo` / snapshot, body restore, lỗi |
| `TopologyTests.swift` | `TopologyTests` (3) | Đồ thị network, cả hai dạng `depends_on`, phân tầng, chu trình |
| `ProxyTests.swift` | `ProxyTests` (6) | Validate route, URL, Caddyfile, chọn upstream, `TarReader` |
| `LocalizationTests.swift` | `LocalizationTests` (8) | File chuỗi vi / en parse được, format specifier khớp, port hiển thị là `3307` (không phải `3.307`) cả trong code lẫn mọi chuỗi vi chứa port, ánh xạ ngôn ngữ |
| `IntegrationTests.swift` | `IntegrationTests` (25) | Xem mục ở trên |
| `VMProfileIntegrationTests.swift` | `VMProfileIntegrationTests` (1) | Xem mục ở trên (cần `COLIMAX_INTEGRATION_VM=1`) |
| `SetupTests.swift` | `SetupTests` (11) | Setup Assistant: formula còn thiếu, phát hiện compose plugin, allowlist tham số `brew install`, merge / backup / 0600 cho docker `config.json` |
| `ChecklistTests.swift` | `ChecklistLogicTests` (3), `ChecklistStoreTests` (11) | Các mục của checklist thủ công chuyển sang unit test: kế hoạch đổi runtime (restart / tạo lại / gõ tên để thu nhỏ), bộ lọc và thứ tự Diagnostics, Storage chỉ xoá volume không dùng được tick, Setup Assistant khi khởi động / cài đặt / huỷ, xác nhận stop / restart VM chỉ khi có container đang chạy, thêm compose project mà không khởi động, thông báo (container thoát, VM, lịch thất bại, cảnh báo tài nguyên một lần) |
| `StoreTests.swift` | `StoreTests` (25) | `AppStore` + model theo màn hình + `OperationCenter` với `FakeColima` / `FakeDocker`: kết nối và reload, một endpoint lỗi, xoá lỗi, events, thao tác VM / profile, khoá busy, giới hạn log, protocol host, fixture UI test |
| `TransferFakeTests.swift` | `TransferFakeTests` (10) | Service với `FakeDocker`: backup / restore volume khứ hồi qua helper, file bị sửa bị từ chối trước khi gọi Docker, tải lỗi giữ file cũ, dọn helper cũ, dump database / lỗi / restore, backup theo lịch, Caddyfile trước khi start proxy |
| `TestSupport.swift` | — | Thư mục tạm dưới `$TMPDIR` |

Tổng: 206 test (180 unit, 26 integration). `scripts/check-strings.sh` kiểm tra các file chuỗi, chuỗi tiếng Việt còn sót trong code, và key bị thiếu.

## Các nhóm tình huống đã phủ

| Nhóm | Test tiêu biểu |
|---|---|
| Happy path | `testRunHappyPath`, `testStreamLines`, `OperationTests.testSuccess`, `testManifestRoundTripAndVerify`, `ContainerDetailsTests.testDecode`, `testParseConfigFixture` |
| Lỗi | `testNonZeroExit`, `testStreamFailureCarriesMessage`, `testHTTPErrorMapping`, `testFailureSetsError`, `testCorruptManifestAndFutureFormat`, `testMissingFile`, `testDumpValidation` |
| Input không hợp lệ | `testWhichRejectsPaths`, `testProfileNameValidation`, `testServiceNameValidation`, `testInvalidServiceRejected`, `testProjectNames`, `testUnixPathParsing`, `testTarValidation`, `testRequestLineAndEscaping` |
| Timeout | `testTimeoutTerminatesProcess` |
| Huỷ | `testCancellationTerminatesProcess`, `testCancelledBeforeStartDoesNotHang`, `testStreamConsumerCancellationStopsProcess`, `testCancellationMarksCancelledNotSucceeded`, integration `testCancelledLogStreamClosesQuickly` |
| Thiếu runtime | `testNotFound`, `testSocketFallbackWhenStatusMissing`, `DiagnosticsTests.testNoProfile`, `testDatabaseBackupRefusesStoppedContainer` |
| Socket không dùng được | `testSocketUnavailable`, `testNotASocket`, `testSocketPathTooLong` |
| Quyền | `testSocketPermissionChecks` |
| Rỗng | `testParseConfigEmpty`, `testDiscoveryEmptyDirectory`, `StorageReportTests.testEmpty`, `testMinimalJSONDecodes`, `testNoManifest` |
| Concurrency | `testConcurrentRuns`, `testLargeOutputDoesNotDeadlock` |
| An toàn dữ liệu và bảo mật | `testRestoreVerifiesBeforeTouchingDocker`, `testTamperedFileIsRejected`, `testTruncatedFileIsRejected`, `testFailedDownloadKeepsExistingFileAndLeavesNoPartial`, `testMissingFileFailsBeforeRunning`, `testArgumentsAreNotInterpretedByShell`, `testArgumentsAreArrays`, `testDumpScriptsAreConstantAndKeepSecretsInContainer`, `testSecurityAuditFindingsAndNoSecretLeak`, integration `testDatabaseBackupFailureLeavesNoFile` |

## Chưa được phủ tự động

- Các luồng UI còn chưa tick trong checklist thủ công bên dưới.
- Docker Scout thật (chỉ parser SARIF được test, với fixture).
- Bản thân timer của `BackupScheduler` và `ResourceWatcher` (một lần chạy / một tick, kể cả thông báo, đã có test).
- Việc macOS hiển thị thông báo (các lời gọi của app được test qua `AppServices.notify`).

## Checklist thủ công trước khi phát hành

Đã kiểm tay UI cho 1.0.0. Các ô `[ ]` bên dưới là template cho lần phát hành sau và không được tick từng mục.

Chạy trên bản build `build/ColimaX.app`, trên Mac Apple Silicon, với ít nhất một profile Colima dùng runtime docker. Dùng tài nguyên test riêng; không bao giờ thao tác trên dữ liệu thật.

Phần lớn checklist đã chuyển sang test tự động. Cách đọc các mục:

- `[x] ~~mục~~ → test`: đã được thay bằng một test tự động đã pass (unit test chạy với `scripts/run-tests.sh`; integration test với `scripts/run-tests.sh --integration`, mục liên quan VM cần thêm `COLIMAX_INTEGRATION_VM=1`).
- UI test (`scripts/ui-tests.sh`, XCUITest với fixture) được ghi là `UI test…`. UI test mới được ghi là `→ UI: test (chưa chạy)` cho tới khi pass ít nhất một lần trên máy thật; trong lúc đó hãy kiểm tra mục đó bằng tay.
- `[ ] mục`: vẫn thủ công: tích hợp hệ thống (menu bar, Dock, Notification Center, login item, keychain, Terminal, trình duyệt), hình ảnh (biểu đồ, đồ thị, theme), hộp thoại lưu file, và mọi thứ cần VM thật.

### Khởi động và điều hướng

- [ ] App mở cửa sổ chính và icon menu bar; icon đổi khi VM đang chạy / đã dừng.
- [x] ~~⌘1…⌘9 mở lần lượt Dashboard, Monitoring, Diagnostics, Containers, Compose, Images, Volumes, Networks, Storage; menu **Go** có Runtime Settings; ⌘, mở Settings~~ → UI `ChecklistUITests.testShortcutsOpenScreensInSidebarOrder`
- [ ] ⌘R làm mới.
- [x] ~~Khi VM đã dừng, các màn Docker hiển thị trạng thái chờ thay vì báo lỗi~~ → UI `testDockerScreensWaitWhileVMIsStopped`

### Setup Assistant (G26)

Logic cài đặt / cấu hình: `SetupTests`. Các trạng thái của sheet là UI test trong `SetupUITests`, điều khiển bằng kịch bản fixture; không cài gì thật.

- [x] ~~Tắt "Show this assistant at launch…" thì sheet không tự mở nữa; khi đã cài đủ công cụ thì không tự mở~~ → `ChecklistStoreTests.testTurningOffShowAtLaunchKeepsTheAssistantClosed`, `testSetupAssistantStaysClosedWhenAllToolsAreInstalled`; ~~cài đặt stream log, kiểm tra lại và làm mới profile; Cancel thì không cài gì~~ → `testSetupInstallStreamsLogThenRechecksAndRefreshesProfiles`, `testCancellingSetupInstallMarksCancelledAndInstallsNothing`.
- [x] ~~Đã cài đủ công cụ: menu app **Setup Assistant…** hiển thị bốn dòng màu xanh và "All tools are installed."~~ → UI `SetupUITests.testAllToolsInstalledShowsGreenRowsAndDoesNotOpenAtLaunch`
- [x] ~~Không có Homebrew: sheet mở khi khởi động, hiển thị lệnh cài đặt chính thức kèm nút **Copy** và link brew.sh, không có nút cài~~ → UI `testNoHomebrewShowsTheInstallCommandAndNoInstallButton`
- [x] ~~Có Homebrew, thiếu công cụ: **Install with Homebrew** hỏi xác nhận, hiển thị đúng lệnh `brew install …`; log stream trong sheet; sau đó các dòng được làm mới~~ → UI `testMissingToolsInstallAsksWithTheExactCommandThenRefreshes`
- [x] ~~Compose plugin đã cài nhưng chưa được nạp: **Configure Plugin** hỏi xác nhận, cập nhật `config.json` của docker CLI (giữ các key khác, ghi `config.json.colimax-backup`)~~ → UI `testConfigurePluginUpdatesTheDockerConfigAndKeepsOtherKeys`
- [x] ~~Chưa có profile Colima nào: **Start Colima** khởi động profile `default` và log stream trong sheet~~ → UI `testNoProfileStartColimaStartsTheDefaultProfile`
- [ ] Trên Mac sạch (hoặc một VM macOS mới): chạy `brew install colima docker docker-compose` thật từ assistant, sau đó `docker compose version` chạy được sau khi **Configure Plugin**.

### Runtime (Dashboard, Runtime Settings, menu bar)

- [x] ~~Start / stop VM, tạo lại VM với disk nhỏ hơn, xoá profile~~ → `VMProfileIntegrationTests.testProfileLifecycleAndDiskShrink`; ~~tên profile không hợp lệ~~ → `testProfileNameValidation`; ~~Stop / Restart khi còn container đang chạy thì hỏi xác nhận (hiện số container); không có container chạy thì thực hiện ngay~~ → `ChecklistStoreTests.testStopAndRestartAskOnlyWhileContainersRun`, `testStopWithoutRunningContainersActsImmediately`, UI `testStopVMWithRunningContainersAsksFirst`; ~~xoá profile thì hỏi xác nhận~~ → UI `testDeleteProfileAsksFirst`.
- [ ] Nút Start / Stop / Restart trên toolbar, Dashboard và menu bar; trạng thái ở sidebar cập nhật mà không cần làm mới tay.
- [x] ~~Thoát (⌘Q) khi đang có thao tác dài thì hỏi trước và huỷ thao tác; không có thao tác thì thoát ngay~~ → UI `testQuitDuringALongOperationAsksFirst`, `testQuitWithoutOperationQuitsAtOnce`
- [ ] Thoát từ menu bar và Dock, và VM cùng container vẫn chạy sau khi thoát.
- [ ] Dashboard tự làm mới (khoảng 15 s) khi đang hiện và ngừng lấy mẫu khi cửa sổ bị thu nhỏ.
- [ ] Dashboard hiển thị CPU / RAM / disk bên trong VM và thông tin Docker.
- [x] ~~Đổi CPU / RAM khi VM đang chạy thì hỏi xác nhận restart. Đổi arch / runtime / VM type thì hỏi xác nhận tạo lại VM, có tuỳ chọn xoá dữ liệu~~ → `ChecklistLogicTests.testRuntimeChangePlanPicksTheRightConfirmation`, UI `testCPUChangeOnRunningVMAsksToRestart`, `testArchChangeAsksToRecreateWithDataOption`
- [x] ~~Tên profile không hợp lệ hoặc đã tồn tại bị chặn trong form~~ → UI `testInvalidProfileNameIsBlocked`
- [x] ~~Huỷ một thao tác dài (ví dụ đang khởi động VM) thì hỏi xác nhận, và trạng thái đổi thành "Cancelled"~~ → UI `testCancellingALongOperationAsksAndMarksItCancelled`; bản thân việc huỷ: `StoreTests.testCancelOperationMarksCancelled`

### Containers

- [x] ~~File log đã export có quyền 0600, kể cả khi ghi đè~~ → `BackupTests.testLogExportPermissionsAfterOverwrite`; ~~backup database tạo file + manifest, container đã dừng bị từ chối~~ → `test{MySQL,MariaDB,Postgres}BackupRestoreRoundTrip`, `testRedisLogicalBackup`, `testDatabaseBackupRefusesStoppedContainer`; ~~biến giống secret bị che và chỉ hiện khi bật "Show Secrets"~~ → UI `testDatabasePasswordIsMaskedUntilRevealed`; ~~xoá container thì hỏi xác nhận~~ → UI `testRemoveContainerCancelKeepsContainer`, `testRemoveContainerConfirmRemovesIt`.
- [ ] Danh sách, lọc, start / stop / restart / pause / unpause; badge ở sidebar với số container đang chạy.
- [ ] Tab Info: health, restart count, OOMKilled, exit code, limit, mount, IP.
- [x] ~~"Copy KEY=VALUE" không dùng được khi một biến nhạy cảm đang bị che~~ → UI `testCopyKeyValueIsUnavailableWhileTheSecretIsMasked`
- [ ] Tab Logs: stream; nút export mở hộp thoại lưu file.
- [ ] Tab Exec chạy được lệnh; "Open Terminal" mở shell vào đúng container.
- [ ] Menu backup database mở hộp thoại lưu file và hiển thị tiến độ.

### Compose

- [x] ~~Project suy ra từ label~~ → `StoreDerivedTests.testComposeProjectsFromLabels`; ~~nhận diện compose file, override, `.env`~~ → `ComposeTests`; ~~up / restart / logs / down / validate / config~~ → `testComposeLifecycle`; ~~thêm project từ thư mục không tự khởi động project~~ → `ChecklistStoreTests.testAddingAComposeProjectFromAFolderDoesNotStartIt`; ~~`down` hỏi xác nhận~~ → UI `testComposeDownAsksFirst`.
- [ ] Danh sách project hiển thị đúng; folder picker thêm được project.
- [ ] Các nút up / down / start / stop / restart / pull.
- [x] ~~Rebuild service thì hỏi xác nhận~~ → UI `testRebuildServiceAsksFirst`
- [ ] Sheet Validate, config đã merge, log theo project và theo từng service.

### Images, Volumes, Networks

- [x] ~~Pull có tiến độ, reference không hợp lệ bị chặn~~ → `testPullImageReportsProgress`, `ImageReferenceTests`; ~~tạo / xoá / prune volume, tạo network có subnet / gateway, prune network~~ → `testVolumeAndNetworkLifecycleWithScopedPrune`; ~~connect / disconnect~~ → `testNetworkConnectDisconnect`; ~~backup / verify / restore volume, file bị sửa đổi bị từ chối trước khi đụng tới Docker~~ → `testVolumeBackupVerifyRestoreRoundTrip`, `testTamperedFileIsRejected`, `testRestoreVerifiesBeforeTouchingDocker`; ~~prune toàn bộ image thì hỏi xác nhận~~ → UI `testPruneAllImagesAsksFirst`; ~~xoá / prune volume thì hỏi xác nhận~~ → UI `testDeleteAndPruneVolumesAsk`.
- [x] ~~Sheet Pull: nút Pull bị vô hiệu với reference không hợp lệ; tiến độ hiện trong panel ở đáy cửa sổ; cột Arch cảnh báo image không phải arm64~~ → UI `testPullIsDisabledForInvalidReferencesAndArchColumnWarns`
- [ ] Xoá image thì hỏi xác nhận.
- [ ] Volumes: hộp thoại tạo; "Verify Backup" hiển thị kết quả; restore file bị sửa đổi thì báo lỗi.
- [x] ~~Networks: form tạo network (kiểm tra subnet / gateway); xoá / prune hỏi xác nhận~~ → UI `testCreateNetworkFormAndDeleteAndPruneAskFirst`
- [ ] Connect / disconnect từ UI.

### Diagnostics, Monitoring, Storage

- [x] ~~Container privileged / bind `0.0.0.0` được báo mà không lộ giá trị secret~~ → `testSecurityAuditOnRealContainer`; ~~port bị process trên host chiếm được báo~~ → `testPortHeldByHostProcessIsReported`; ~~thống kê CPU / RAM theo từng container~~ → `testStatsOneShotAndMetricsHistory`; ~~volume không dùng, image dangling, container đã dừng~~ → `testStorageReportWithRealDiskUsage`; ~~lọc theo nhóm, ẩn mục OK~~ → `ChecklistLogicTests.testDiagnosticsGroupFilterHideOKAndOrder`; ~~chỉ volume được tick mới bị xoá~~ → `testStorageCleanupRemovesOnlyTickedUnusedVolumes`.
- [ ] Diagnostics chạy xong, ⇧⌘R chạy lại.
- [ ] Monitoring hiển thị bảng CPU / RAM / Net / Block I/O cập nhật liên tục.
- [ ] Storage hiển thị các nhóm và build cache; mọi thao tác dọn dẹp đều hỏi xác nhận.

### Backup nâng cao, công cụ (P2 / P3)

- [x] ~~Restore database chặn dump sai engine / bị cắt cụt~~ → `RestoreTests` (preflight), các integration round-trip; ~~"Run Now" của lịch backup tạo file + manifest, giới hạn giữ lại giữ đúng N bản và không xoá file nào khác~~ → `testScheduledBackupRunNow`; ~~thử lại sau 15 phút khi lỗi~~ → `ScheduleTests.testDueLogicAndRetryAfterFailure`; ~~lịch bị lỗi (VM đã dừng) ghi lại lỗi và gửi thông báo~~ → `ChecklistStoreTests.testScheduledBackupFailureShowsErrorAndNotifies`; ~~ghi / đọc lịch sử, cảnh báo một lần cho đến khi hồi phục, đúng một thông báo~~ → `AlertTests`, `testStatsOneShotAndMetricsHistory`, `testResourceAlertNotifiesOnceUntilRecovery`; ~~Trivy thật tạo ra bảng CVE~~ → `testTrivyScanParsesRealOutput`; ~~container đích vẫn truy cập được sau khi restart, `compose down` project đích không bị lỗi network~~ → `testLocalProxyFollowsTargetRestart`, `testComposeDownWithProxyRouteSucceeds`; ~~Elasticsearch tạo / restore (bản sao và ghi đè) / xoá / export~~ → `testElasticsearchSnapshotRoundTrip` (`COLIMAX_INTEGRATION_ES=1`).
- [x] ~~Restore database: xác nhận yêu cầu gõ đúng tên container; lỗi preflight hiện ra trước hộp thoại xác nhận~~ → UI `testDatabaseRestoreRequiresTheTypedContainerName`, `testDatabaseRestorePreflightErrorAppearsBeforeThePrompt`
- [ ] Backups: form tạo lịch volume / database, nút "Run Now", hiển thị lần chạy gần nhất / lỗi gần nhất.
- [ ] Monitoring → History & Alerts: biểu đồ có dữ liệu sau vài phút.
- [x] ~~Images → Scan: không có scanner thì hiển thị hướng dẫn cài~~ → UI `testScanWithoutScannerShowsInstallInstructions`
- [ ] Có Trivy thì bảng CVE lọc được theo mức độ và "Fix available".
- [x] ~~Container Elasticsearch không có `path.repo`: Snapshots… hiển thị hướng dẫn~~ → UI `testSnapshotsWithoutPathRepoShowGuidance`
- [ ] Topology: đồ thị network ↔ container, highlight khi hover; phụ thuộc Compose theo tầng.
- [ ] Local Domains: Start Proxy, thêm domain, mở link trong trình duyệt; Trust / Remove Trust CA (hộp thoại quyền admin).

### Preferences và hệ thống

- [x] ~~Port hiển thị là `3307`, không phải `3.307`~~ → `LocalizationTests.testIdentifierNumbersAreNotGrouped`, `testVietnamesePortStringsRenderPlainDigits`; ~~thu nhỏ disk bằng cách tạo lại VM~~ → `VMProfileIntegrationTests`; ~~dọn helper `dev.colimax.helper` còn sót mà không đụng tới container khác~~ → `testCleanupStaleHelpersOnlyRemovesTestHelpers`, `BackupTests.testStaleHelperSelection`; ~~gửi thông báo khi VM khởi động xong, một container thoát với exit code khác 0, một lịch backup thất bại, vượt ngưỡng tài nguyên (và không gửi khi đã tắt)~~ → `ChecklistStoreTests.testVMStartNotifiesWhenEnabled`, `testContainerExitNotifiesOnlyForUnexpectedNonZeroExits`, `testScheduledBackupFailureShowsErrorAndNotifies`, `testResourceAlertNotifiesOnceUntilRecovery`.
- [x] ~~Ngôn ngữ: UI hiển thị tiếng Việt với `-AppleLanguages (vi)`~~ → UI `testVietnameseUIIsTranslated`
- [ ] Bộ chọn English / Tiếng Việt / System và Restart Now khởi động lại với ngôn ngữ đã chọn.
- [x] ~~Runtime Settings: bật "Unlock a smaller disk for this change", chọn disk nhỏ hơn → xác nhận bằng cách gõ tên profile; công tắc tự tắt lại sau khi rời màn hình~~ → UI `testShrinkingTheDiskNeedsTheTypedProfileNameAndUnlockResets`
- [ ] Theme Light / Dark / System áp dụng ngay; ẩn / hiện icon Dock.
- [ ] Bật / tắt được Launch at login (bản build `.app`).
- [ ] macOS hiển thị thông báo (Notification Center, kèm icon của app).
- [ ] Thoát app khi đang backup volume rồi mở lại: helper được dọn sau khoảng 10 phút (khi app chạy cơ chế dọn tự động).

## Xử lý sự cố

**Icon thông báo trống trên máy dev.** Notification Center nhớ đường dẫn app lúc bundle ID xin quyền thông báo lần đầu. Nếu đó là một bản build cũ đã bị xoá (hoặc di chuyển), thông báo hiện icon mặc định dù Dock và Finder vẫn hiện đúng icon. Người dùng cài bản phát hành lần đầu không bị. Cùng bản build nhưng bundle ID mới (`BUNDLE_ID=dev.colimax.ColimaX.icontest scripts/build-app.sh`) hiện đúng icon. Cách xoá bản ghi cũ (cần Full Disk Access cho Terminal; sao lưu trước):

```bash
DB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
[ -f "$DB" ] || DB="$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db"
cp "$DB" ~/Desktop/usernoted-db-backup
sqlite3 "$DB" "select app_id, identifier from app where identifier like 'dev.colimax%';"
sqlite3 "$DB" "delete from app where identifier = 'dev.colimax.ColimaX';"
killall usernoted NotificationCenter
```

Sau đó mở `/Applications/ColimaX.app` và cho phép thông báo lại. Gỡ đăng ký các bản cùng bundle ID còn sót: `lsregister -dump | grep -E "path:.*ColimaX.*\.app"`, rồi `lsregister -u <đường dẫn>` (công cụ nằm ở `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/`).
