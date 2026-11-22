# Lộ trình

[English](ROADMAP.md) · Tiếng Việt

Kế hoạch phiên bản của ColimaX. Trạng thái từng mục do [FEATURES.vi.md](FEATURES.vi.md) quyết định; điểm V / C / R (giá trị / độ phức tạp / rủi ro, thang 1–5) lấy từ [AUDIT.vi.md](AUDIT.vi.md). Trước khi nhận một mục, cập nhật trạng thái trong FEATURES.md như mô tả trong [AGENTS.vi.md](../AGENTS.vi.md).

## 1.0.0 — bản phát hành đầu tiên

Code đã đủ tính năng; mọi mục trong [FEATURES.vi.md](FEATURES.vi.md) đều có release 1.0.0. Phạm vi:

- Runtime: quản lý VM và profile Colima; cấu hình CPU / RAM / disk / VM type / mount / Rosetta / k3s; Docker endpoint lấy từ `colima status --json`; cập nhật realtime.
- Containers: thao tác, chi tiết (health, OOMKilled, exit code, resource limits, env che secret), logs và export, exec, Terminal.
- Compose: project từ label và thư mục, thao tác theo project và từng service, logs, validate, config.
- Images / Volumes / Networks: quản lý đầy đủ, kiến trúc image, connect / disconnect network, quét lỗ hổng bằng Trivy / Docker Scout.
- Backup: volume `.tar` có manifest SHA-256 và verify trước khi restore; dump và restore MySQL / MariaDB / PostgreSQL / Redis; lịch backup có retention; snapshot Elasticsearch / OpenSearch.
- Diagnostics & Security: kiểm runtime, Apple Silicon, security audit chỉ đọc, xung đột port.
- Monitoring & Storage: tài nguyên theo container, lấy mẫu nền có lịch sử và cảnh báo ngưỡng, phân tích dung lượng và dọn dẹp.
- Tools: topology network / Compose, domain local (`*.localhost` qua Caddy, HTTPS local).
- App: menu bar, Preferences, Setup Assistant, phím tắt ⌘1…⌘9, huỷ thao tác dài, tiếng Anh và tiếng Việt.
- Engineering: protocol service kèm fake trong bộ nhớ, model theo màn hình, UI test XCUITest (T6–T10; thiết kế trong [ARCHITECTURE.vi.md](ARCHITECTURE.vi.md) mục 8).

### Trước khi phát hành 1.0.0

| Việc | Lý do | Cách làm |
|---|---|---|
| Đăng ký domain `colimax.dev` | Bundle ID `dev.colimax.ColimaX` dựa trên domain này, và trang giới thiệu (`site/`) sẽ chạy ở đó | [RELEASE.vi.md](RELEASE.vi.md) mục 2.5 |
| Apple Developer Program + certificate | Cần để ký Developer ID; thiếu nó Gatekeeper chặn app trên máy khác | Thiết lập một lần theo [RELEASE.vi.md](RELEASE.vi.md) mục 2 |
| Repository GitHub + secret | CI và workflow Release cần repository và secret certificate / notarize; private vulnerability reporting được bật cùng repository | [RELEASE.vi.md](RELEASE.vi.md) mục 2.4 |
| Beta `1.0.0-beta.1` | Thu thập lỗi từ người dùng thật trước bản chính thức | [RELEASE.vi.md](RELEASE.vi.md) mục 3.2 |

Đã xong:

- Unit test, integration test (gồm cả Elasticsearch và vòng đời VM) và UI test pass trên VM Colima thật; xem [FEATURES.vi.md](FEATURES.vi.md#verify).
- Kiểm tay UI theo [TESTING.vi.md](TESTING.vi.md).
- Trang giới thiệu trong `site/` (tiếng Anh + tiếng Việt), được workflow Pages publish khi có repository.
- License: MIT ([LICENSE](../LICENSE)).
- Icon app: monogram CX, `Resources/AppIcon.icns` sinh bởi `scripts/make-icon.sh` và đóng gói qua `CFBundleIconFile`.
- Hạ tầng phát hành: `scripts/release.sh`, `scripts/make-dmg.sh`, `scripts/notarize.sh`, GitHub Actions CI + Release (nháp), template issue/PR, [RELEASE.vi.md](RELEASE.vi.md). Chưa chạy thật: cần certificate Developer ID và repository GitHub.

## Sau này

Chưa có mục nào được lên kế hoạch. Ứng viên:

- UX: hiện lỗi ngay tại chỗ thay vì một banner chung chung; cột restart count trong danh sách Containers ([AUDIT.vi.md](AUDIT.vi.md) mục 6).
- Terminal nhúng trong app thay vì mở Terminal.app.
- Hỗ trợ runtime containerd (nerdctl) và màn hình Kubernetes.
