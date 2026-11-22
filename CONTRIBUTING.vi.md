# Đóng góp cho ColimaX

[English](CONTRIBUTING.md) · Tiếng Việt

Các quy tắc này áp dụng cho cả người đóng góp lẫn coding agent. Agent cần đọc thêm [AGENTS.vi.md](AGENTS.vi.md). Mọi người tham gia đều phải tuân theo [Quy tắc ứng xử](CODE_OF_CONDUCT.vi.md).

## Giấy phép

ColimaX phát hành theo giấy phép MIT ([LICENSE](LICENSE)). Mọi đóng góp gửi vào repository này đều được cấp phép theo MIT.

## Quy trình

1. **Đọc [docs/FEATURES.vi.md](docs/FEATURES.vi.md) trước tiên.** Đó là nguồn sự thật duy nhất về trạng thái tính năng (Planned / In Progress / Implemented / Verified / Blocked). Tìm trong cột Code của file này và trong `Sources/ColimaX` để tránh làm trùng việc đã có.
2. **Nhận việc:** đổi dòng của tính năng sang `In Progress (<người/agent>)`. Tính năng mới chưa có ID thì thêm một dòng với ID mới và mức ưu tiên.
3. **Làm việc** theo chuẩn code bên dưới. Giữ thay đổi nhỏ và đúng phạm vi.
4. **Build và test** (bắt buộc, xem bên dưới).
5. **Cập nhật tài liệu:** trạng thái, cột Code và Ghi chú trong `docs/FEATURES.md` (chỉ trạng thái hiện tại, không ghi ngày); [CHANGELOG.md](CHANGELOG.md) dưới mục `[Unreleased]` (tạo mục này ở đầu file nếu chưa có) cho các thay đổi người dùng thấy được; [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [SECURITY.md](SECURITY.md) hoặc [docs/TESTING.md](docs/TESTING.md) khi bạn thay đổi thiết kế, một biện pháp bảo mật hoặc cách test.
6. Chỉ đánh dấu một tính năng là `Verified` khi nó đã thực sự chạy với Colima / Docker (integration test hoặc thao tác tay), kèm cách verify (tên test hoặc lệnh).

## Chuẩn code

- **Swift 6 strict concurrency, 0 warning.** State UI nằm trên `@MainActor`; I/O blocking đi qua `BlockingIO.run`. Không dùng `Task.detached` để chờ socket hay pipe.
- **Không bao giờ chạy lệnh bằng cách nối chuỗi vào shell.** Dùng `Shell.run` / `Shell.stream` với mảng tham số. Tham số do người dùng nhập phải qua validator; path và query của Docker API dùng `DockerClient.escape`.
- **Thao tác destructive phải có xác nhận** qua `Confirm.destructive` hoặc `Confirm.ask`.
- **Không tạo service, model hay view trùng lặp.** Mở rộng các type đã có.
- Logic thuần (parser, validator, check) đặt trong service để unit test được bằng fixture. View không chứa business logic.
- File chứa dữ liệu người dùng (backup, log, manifest) được ghi bằng `AtomicFile` hoặc file tạm rồi rename, với quyền 0600.
- Không bao giờ ghi giá trị secret vào log, kết quả Diagnostics hay thông báo lỗi.
- Không thêm dependency bên thứ ba khi chưa thống nhất trước (xem ADR-3 trong [docs/ARCHITECTURE.vi.md](docs/ARCHITECTURE.vi.md)).
- Chuỗi hiển thị cho người dùng phải được bản địa hoá: viết bằng tiếng Anh trong code và thêm bản dịch tiếng Việt vào `Resources/vi.lproj/Localizable.strings`. `scripts/check-strings.sh` phải pass.

## Build và test trước khi gửi

```bash
scripts/dev-build.sh                 # phải báo 0 warning, 0 error
scripts/run-tests.sh                 # unit test phải pass
scripts/run-tests.sh --integration   # khi đụng tới Docker API, backup hoặc endpoint (cần VM Colima đang chạy)
scripts/check-strings.sh             # khi thêm hoặc sửa chuỗi UI
scripts/ui-tests.sh                  # khi đụng tới hộp xác nhận hoặc hiển thị secret (cần Xcode, xem docs/TESTING.vi.md)
```

Integration test dùng profile Colima có tên trong `COLIMAX_PROFILE` (mặc định `default`). CI chạy `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh`, có warning là fail.

Thay đổi UI: chạy `scripts/build-app.sh`, mở `build/ColimaX.app` và đi qua các mục liên quan trong checklist kiểm tra tay ở [docs/TESTING.vi.md](docs/TESTING.vi.md).

Test mới đặt trong `Tests/ColimaXTests`. Integration test chỉ được tạo tài nguyên có tiền tố `colimax-test-` và label `dev.colimax.test`, dọn dẹp trong `tearDown`, và không bao giờ đụng vào tài nguyên sẵn có của người dùng.

## Quy ước commit

Theo [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>(<scope>): <short description>
```

| Type | Dùng cho |
|---|---|
| `feat` | Tính năng mới |
| `fix` | Sửa lỗi |
| `perf` | Cải thiện hiệu năng |
| `refactor` | Tái cấu trúc, không đổi hành vi |
| `test` | Thêm hoặc sửa test |
| `docs` | Chỉ tài liệu |
| `build` | Script build, `Package.swift` |
| `chore` | Những việc khác không ảnh hưởng tới code chạy |

Scope gợi ý: `runtime`, `containers`, `compose`, `images`, `volumes`, `backup`, `networks`, `diagnostics`, `storage`, `monitoring`, `ui`, `docs`. Ghi ID tính năng vào phần body của commit nếu có (ví dụ `Refs: G19`).

## Pull request

Điền template pull request: thay đổi gì và vì sao, ID tính năng liên quan trong `docs/FEATURES.md`, và checklist (build, test, kiểm tra UI, xác nhận, không nối chuỗi shell, đã cập nhật tài liệu). Báo lỗ hổng bảo mật một cách riêng tư như mô tả trong [SECURITY.vi.md](SECURITY.vi.md), không báo qua issue hay pull request công khai.

## Cấu trúc project

```
Sources/ColimaX/
├── App/                  # @main app, scenes, command menus, AppStore, OperationCenter, AppServices, AppSettings, Preferences
├── Core/                 # Shell, BlockingIO, Hashing, Utilities, SystemIntegration
│   ├── Colima/           # ColimaControlling, LiveColima, ColimaService
│   └── Docker/           # DockerEngine, DockerClient, DockerAPI, DockerModels, ContainerDetails
├── Testing/              # FakeColima, FakeDocker, UITestFixtures (chỉ khi -D COLIMAX_UI_TESTING)
├── UI/                   # Component SwiftUI dùng chung
└── Features/<Feature>/   # View, model màn hình, service và store của từng tính năng
Tests/ColimaXTests/       # Unit test và integration test
Tests/Runner/             # Runner cho scripts/run-tests.sh
UITests/                  # Project XCUITest (scripts/ui-tests.sh)
scripts/                  # Script build, test, bản địa hoá và phát hành
docs/                     # Tài liệu project (xem docs/README.vi.md)
```

Code mới đặt trong thư mục của tính năng mà nó thuộc về. Code dùng chung cho nhiều tính năng đặt trong `Core/` (không phải UI) hoặc `UI/` (view).

## Thêm một tính năng

Làm theo các bước trong [docs/ARCHITECTURE.vi.md](docs/ARCHITECTURE.vi.md#thêm-một-màn-hình-tính-năng): logic thuần trong service, lời gọi Docker / Colima mới thêm vào `DockerEngine` / `ColimaControlling` và fake tương ứng, model màn hình phụ thuộc `DockerContext` hoặc `ProfileContext` (không phụ thuộc `AppStore`) và chạy action qua `OperationCenter`, unit test với fake, và UI test khi luồng là destructive hoặc hiển thị secret. Đánh dấu tính năng `In Progress` trong [docs/FEATURES.vi.md](docs/FEATURES.vi.md) trước.
