[English](AGENTS.md) · Tiếng Việt

# Hướng dẫn cho agent (Codex, Cursor, Claude Code…)

1. **Đọc `docs/FEATURES.md` (tiếng Anh) trước tiên.** Đó là nguồn sự thật duy nhất về trạng thái tính năng (Planned / In Progress / Implemented / Verified / Blocked). `docs/FEATURES.vi.md` chỉ là bản dịch.
2. Trước khi bắt đầu một tính năng: đổi dòng của nó sang `In Progress (<agent>)`. Xong việc thì cập nhật trạng thái, cột Code, cột Release và Ghi chú. Tài liệu chỉ mô tả trạng thái hiện tại: không ghi ngày tháng hay nhật ký ai làm gì khi nào (lịch sử nằm trong git và `CHANGELOG.md`).
3. `Verified` chỉ được ghi khi đã chạy thật trên Colima/Docker (integration test `scripts/run-tests.sh --integration` hoặc thao tác tay), kèm cách verify (tên test hoặc lệnh).
4. Không tạo service/model/view trùng. Tìm trong cột Code của `docs/FEATURES.md` và trong `Sources/ColimaX` trước.
5. Đặt file mới đúng chỗ trong `Sources/ColimaX`:
   - `App/`: entry point, cửa sổ chính, menu bar, Preferences, state toàn cục (`AppStore`, `AppSettings`).
   - `Core/`: hạ tầng dùng chung (`Shell`, `BlockingIO`, tích hợp hệ thống); `Core/Docker/` client Docker Engine API + model; `Core/Colima/` Colima CLI.
   - `Features/<Tên>/`: view + store + service riêng của một màn hình / tính năng.
   - `UI/`: component SwiftUI dùng chung.
   - `Testing/`: fake trong bộ nhớ và fixture cho UI test, chỉ biên dịch khi có `-D COLIMAX_UI_TESTING`.
   Thư mục chỉ để tổ chức; quy tắc phụ thuộc vẫn là View → Store → Service (xem `docs/ARCHITECTURE.md`).
6. Build & test: `scripts/dev-build.sh` (0 warning), `scripts/run-tests.sh` (unit), `scripts/run-tests.sh --integration` (cần VM Colima đang chạy, profile qua `COLIMAX_PROFILE`), `scripts/check-strings.sh` (bản dịch), `scripts/build-app.sh` (đóng gói `build/ColimaX.app`).
7. Ràng buộc: Swift 6 strict concurrency, 0 warning; không chạy lệnh qua shell bằng cách nối chuỗi input; thao tác destructive phải có xác nhận; integration test chỉ tạo tài nguyên `colimax-test-*` có label `dev.colimax.test` và tự dọn; chuỗi UI viết tiếng Anh trong code và dịch ở `Resources/vi.lproj`.
8. Ngôn ngữ: mọi tài liệu viết tiếng Anh là bản chính, kèm bản tiếng Việt `<tên>.vi.md` cạnh nó (ví dụ `README.vi.md`, `docs/FEATURES.vi.md`, `AGENTS.vi.md`); sửa bản tiếng Anh thì cập nhật bản `.vi.md` trong cùng một thay đổi. Comment trong code và thông báo của script viết tiếng Anh. Chuỗi UI dùng key tiếng Anh trong code, dịch ở `Resources/vi.lproj`.

Tên sản phẩm, module, target và executable đều là `ColimaX`. Chi tiết: `CONTRIBUTING.md` (quy trình, commit), `docs/ARCHITECTURE.md` (kiến trúc), `docs/AUDIT.md` (rủi ro và ưu tiên), `docs/README.md` (mục lục tài liệu).
