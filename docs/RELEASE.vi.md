# Quy trình phát hành ColimaX

[English](RELEASE.md) · Tiếng Việt

Hướng dẫn này dành cho người phát hành bản mới, kể cả người chưa từng phát hành app macOS. Hoàn thành **Thiết lập một lần** trước, sau đó làm theo **Quy trình mỗi lần phát hành** cho mọi bản phát hành.

> ColimaX chạy ngoài App Sandbox (cần gọi `colima` và đọc Docker socket), nên **không phát hành qua Mac App Store**. Kênh phát hành: DMG trên GitHub Releases (và Homebrew cask sau này). Để macOS cho người dùng mở app mà không cảnh báo, bản phát hành **bắt buộc** phải được ký bằng Developer ID và notarize bởi Apple.

## 0. Có bắt buộc tham gia Apple Developer Program không?

Không bắt buộc, nhưng nó quyết định trải nghiệm cài đặt:

| | Không tham gia (miễn phí) | Developer ID (99 USD/năm) |
|---|---|---|
| Ký | Ad-hoc (mặc định của `scripts/build-app.sh`) | Developer ID + notarization (`scripts/release.sh`) |
| Người dùng tải DMG | Bị Gatekeeper chặn; người dùng phải mở app một lần, rồi vào **System Settings → Privacy & Security → Open Anyway** (macOS 15+ không còn hỗ trợ chuột phải → Open), hoặc chạy `xattr -dr com.apple.quarantine /Applications/ColimaX.app` | Mở được ngay, không cảnh báo |
| Build từ source | Không bị chặn (app build local không có cờ quarantine) | Không bị chặn |
| Homebrew cask chính thức | Không phù hợp (Homebrew đang siết quy định với cask không notarize; kiểm tra chính sách hiện hành) | Phù hợp |
| Phù hợp cho | Beta cho developer, dùng nội bộ | Phát hành công khai |

**Khuyến nghị:** beta nội bộ hoặc beta cho developer có thể phát hành dạng build ad-hoc kèm hướng dẫn ở mục 3.6; với bản 1.0.0 công khai, hãy đăng ký Developer ID.

## 1. Khái niệm

| Thuật ngữ | Ý nghĩa |
|---|---|
| **Commit** | Một điểm lưu trong lịch sử mã nguồn. Commit thường xuyên; không cần đợi đến khi một việc "xong". |
| **Release** | Một phiên bản người dùng tải được: tag `vX.Y.Z` + DMG đã ký và notarize trên GitHub Releases. |
| **SemVer** | `MAJOR.MINOR.PATCH`. PATCH: sửa bug. MINOR: tính năng tương thích ngược. MAJOR: thay đổi phá vỡ tương thích. Pre-release: `1.0.0-beta.1`. |
| **Developer ID Application** | Certificate của Apple dùng để ký app phát hành ngoài App Store. |
| **Notarize** | Apple tự động quét file đã ký (vài phút) và cấp một "ticket". Không có ticket thì Gatekeeper chặn app. |
| **Staple** | Gắn ticket vào file để file mở được kể cả khi Mac của người dùng offline. |
| **Gatekeeper** | Cơ chế của macOS kiểm tra chữ ký + ticket khi mở app tải từ Internet. |

Nguồn duy nhất của số phiên bản: file [`VERSION`](../VERSION). Build number: tự tăng (CI dùng `github.run_number`).

## 2. Thiết lập một lần

### 2.1 Apple Developer Program

1. Đăng ký tại developer.apple.com/programs (99 USD/năm, cá nhân hoặc tổ chức; tổ chức cần số D-U-N-S).
2. Ghi lại **Team ID** (10 ký tự) ở trang Membership.

### 2.2 Certificate Developer ID Application

1. Mở **Xcode → Settings → Accounts** và đăng nhập Apple ID của tài khoản developer.
2. **Manage Certificates… → + → Developer ID Application**.
3. Kiểm tra:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (TEAMID)"
   ```
   Chuỗi trong ngoặc kép chính là `SIGN_IDENTITY` của bạn.
4. **Sao lưu** certificate: Keychain Access → My Certificates → chuột phải → Export (.p12, với mật khẩu mạnh). Cất trong password manager. Mất private key nghĩa là phải tạo certificate mới.

### 2.3 Thông tin xác thực notarization

**Máy developer** (lưu trong Keychain, làm một lần):
```bash
xcrun notarytool store-credentials colimax \
  --apple-id <apple-id-email> --team-id <TEAMID>
# enter an app-specific password created at appleid.apple.com → Sign-In and Security → App-Specific Passwords
```
Sau đó dùng `NOTARY_PROFILE=colimax`.

**CI** (khuyến nghị dùng API key thay vì mật khẩu):
1. App Store Connect → Users and Access → Integrations → **App Store Connect API** → tạo key với role *Developer*.
2. Tải file `.p8` (chỉ tải được **một lần**), và ghi lại **Key ID** và **Issuer ID**.

### 2.4 GitHub repository

1. Tạo repository (tên gợi ý `colimax`) và push nhánh `main`.
2. Nếu repository không phải `trongcong/colimax`, sửa URL trong `.github/ISSUE_TEMPLATE/config.yml` và `site/`.
3. **Settings → Code security → Private vulnerability reporting → Enable** (kênh riêng tư miễn phí để nhận báo cáo lỗ hổng; xem [SECURITY.vi.md](../SECURITY.vi.md)).
4. **Settings → Environments → New environment `release`**:
   - *Required reviewers*: chính bạn, để mọi lần phát hành đều cần phê duyệt rõ ràng. Để tắt *Prevent self-review* (người duy trì một mình phải tự duyệt được) và tắt *Allow administrators to bypass* để không ai bỏ qua được bước duyệt.
   - *Deployment branches and tags*: *Selected branches and tags* → thêm rule tag `v*.*.*`, ref duy nhất mà workflow Release chạy. Khi đó không nhánh hay workflow nào khác dùng được secret ký app.
5. **Settings → Secrets and variables → Actions**: thêm secret vào environment `release`:

   | Secret | Nguồn |
   |---|---|
   | `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12 \| pbcopy` |
   | `MACOS_CERT_PASSWORD` | mật khẩu file .p12 |
   | `SIGN_IDENTITY` | chuỗi ở bước 2.2 |
   | `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
   | `NOTARY_KEY_ID` | Key ID |
   | `NOTARY_ISSUER_ID` | Issuer ID |

   Biến tuỳ chọn: `BUNDLE_ID` (mặc định `dev.colimax.ColimaX`).
6. **Settings → Branches**: bảo vệ `main` và yêu cầu check **CI** pass trước khi merge.

### 2.5 Domain và trang sản phẩm

Trang giới thiệu nằm trong `site/` (`index.html` tiếng Anh, `vi/index.html` tiếng Việt, dùng chung `style.css`; HTML thuần, không có bước build). Workflow **Pages** (`.github/workflows/pages.yml`) publish trang mỗi khi `site/` thay đổi trên `main`. Xem thử trên máy bằng `python3 -m http.server -d site 8000`. Ảnh chụp trong `site/img/` lấy từ dữ liệu demo, không bao giờ chụp từ máy thật: sau khi UI thay đổi đáng kể, chạy `scripts/site-screenshots.sh` (script mở từng màn hình và nhờ bạn click vào cửa sổ) rồi xem lại ảnh trước khi commit.

1. **Settings → Pages → Build and deployment → Source: GitHub Actions**, rồi chạy workflow **Pages** một lần (hoặc push một thay đổi trong `site/`). Trang chạy ở `https://<owner>.github.io/colimax/`. Với gói Free, Pages cần repository public.
2. Đăng ký `colimax.dev` (bundle ID `dev.colimax.ColimaX` khớp với domain này).
3. **Verify domain trước**: Settings của tài khoản GitHub → Pages → *Add a domain*, rồi thêm bản ghi TXT mà GitHub đưa ra. Việc này ngăn người khác nhận domain cho trang Pages của họ.
4. **Settings của repository → Pages → Custom domain**: nhập `colimax.dev` và lưu, *trước khi* tạo bản ghi DNS. Deploy bằng Actions thì không cần file `CNAME`; nếu có, GitHub cũng bỏ qua.
5. DNS ở nhà đăng ký domain (xoá các bản ghi parking mặc định):

   | Host | Loại | Giá trị |
   |---|---|---|
   | `@` | A | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` |
   | `@` | AAAA | `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153` |
   | `www` | CNAME | `<owner>.github.io` (không kèm tên repository) |

   Thay cho bản ghi A / AAAA, có thể dùng một bản ghi ALIAS / ANAME ở `@` trỏ về `<owner>.github.io` nếu nhà cung cấp hỗ trợ. Không tạo bản ghi wildcard (`*.colimax.dev`).
6. Kiểm bằng `dig colimax.dev +noall +answer -t A` (DNS có thể mất tới 24 giờ để cập nhật), rồi tick **Enforce HTTPS** khi GitHub đã cấp chứng chỉ. `.dev` nằm trong danh sách HSTS preload nên trình duyệt chỉ mở qua HTTPS: trang chưa vào được cho tới khi có chứng chỉ.
7. Sau bản phát hành đã ký đầu tiên, đổi nút chính ở cả hai trang từ "Build từ mã nguồn" sang tải DMG.

## 3. Quy trình mỗi lần phát hành

### 3.1 Chuẩn bị (trên nhánh `main` sạch)

- [ ] Mọi tính năng trong bản này đều ở trạng thái `Implemented` hoặc `Verified` trong [FEATURES.vi.md](FEATURES.vi.md); không còn mục nào `In Progress`.
- [ ] `WARNINGS_AS_ERRORS=1 scripts/dev-build.sh` → 0 warning.
- [ ] `scripts/run-tests.sh --integration` trên máy có Colima → 0 lỗi.
- [ ] Kiểm tra UI thủ công theo checklist trong [TESTING.vi.md](TESTING.vi.md).
- [ ] Test trên **máy sạch** hoặc một tài khoản user macOS mới (chưa từng chạy ColimaX), trên macOS 14 và macOS mới nhất.
- [ ] Cập nhật `VERSION`.
- [ ] `CHANGELOG.md`: đổi `## [Unreleased]` thành `## [X.Y.Z] - YYYY-MM-DD`.
- [ ] Commit: `chore(release): X.Y.Z`.

### 3.2 Beta trước bản chính thức (khuyến nghị cho mọi bản MINOR/MAJOR)

1. Đặt `VERSION` thành `X.Y.Z-beta.1` và thêm mục tương ứng trong CHANGELOG.
2. Phát hành như ở 3.3; workflow tự đánh dấu release là *pre-release* khi phiên bản chứa `-`.
3. Gửi cho 3–10 tester và thu thập bug trong 1–2 tuần.
4. Sửa bug → `beta.2`… → khi đã ổn định thì phát hành `X.Y.Z`.

### 3.3 Phát hành

**Cách A: tự động (khuyến nghị):**
```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```
Workflow **Release** chạy: kiểm tra tag khớp `VERSION` → unit test → build → ký → notarize app → DMG → notarize DMG → tạo GitHub Release dạng **draft** kèm DMG + SHA-256 + release notes trích từ CHANGELOG.

**Cách B: thủ công, trên máy developer:**
```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=colimax scripts/release.sh
git tag vX.Y.Z && git push origin vX.Y.Z
gh release create vX.Y.Z build/ColimaX-X.Y.Z.dmg build/ColimaX-X.Y.Z.dmg.sha256 --draft --title "ColimaX X.Y.Z" --notes-file <notes.md>
```

### 3.4 Kiểm tra bản draft trước khi publish

- [ ] Tải DMG từ bản draft về **một máy khác** (hoặc xoá bản cũ) và mở trong Finder.
- [ ] Không có cảnh báo Gatekeeper; kiểm tra thêm:
  ```bash
  spctl --assess --type execute --verbose=2 /Applications/ColimaX.app
  # → accepted, source=Notarized Developer ID
  shasum -a 256 ColimaX-X.Y.Z.dmg   # must match the .sha256 file
  ```
- [ ] Mở app và chạy nhanh qua Dashboard, Containers và Diagnostics.
- [ ] Bấm **Publish release**.

### 3.5 Sau khi phát hành

- [ ] Thêm mục `## [Unreleased]` mới ở đầu CHANGELOG.
- [ ] Cập nhật [FEATURES.vi.md](FEATURES.vi.md) (cột Release) nếu cần.
- [ ] Cập nhật Homebrew cask (khi đã có tap).
- [ ] Theo dõi issue mới trong 48 giờ đầu.

### 3.6 Phát hành không có Developer ID (beta / nội bộ)

```bash
scripts/build-app.sh          # ad-hoc signing
scripts/make-dmg.sh           # DMG + .sha256 (DMG is not signed)
```

Tạo GitHub Release thủ công dưới dạng **pre-release**, đính kèm DMG + `.sha256`, và ghi rõ trong release notes:

> Bản build này chưa được Apple notarize. Sau khi kéo ColimaX vào Applications, mở app một lần, rồi vào **System Settings → Privacy & Security → Open Anyway**. Hoặc chạy: `xattr -dr com.apple.quarantine /Applications/ColimaX.app`. Kiểm tra checksum bằng: `shasum -a 256 ColimaX-X.Y.Z.dmg`.

Workflow **Release** trên GitHub cần các secret Developer ID, nên không dùng được trong trường hợp này.

## 4. Xử lý sự cố

| Triệu chứng | Nguyên nhân / cách sửa |
|---|---|
| Người dùng thấy "ColimaX is damaged / can't be opened" | Bản build được ký ad-hoc hoặc chưa notarize. Chỉ phát hành bản build tạo bởi `scripts/release.sh`. |
| `notarytool` trả về `Invalid` | Đọc log do `scripts/notarize.sh` in ra. Nguyên nhân thường gặp: thiếu `--timestamp`, thiếu Hardened Runtime (các script đã xử lý), binary ký sai identity. |
| `The signature does not include a secure timestamp` | Ký mà không có `--timestamp`; dùng `scripts/build-app.sh` với `SIGN_IDENTITY` là Developer ID. |
| Workflow lỗi ở bước import certificate | Secret base64 sai (thừa ký tự xuống dòng) hoặc mật khẩu .p12 sai. |
| Tag không khớp `VERSION` | Workflow cố ý dừng. Xoá tag (`git tag -d vX && git push origin :refs/tags/vX`), sửa `VERSION`, rồi tag lại. |

## 5. Hotfix và thu hồi bản phát hành lỗi

- **Hotfix:** sửa trên `main` → tăng PATCH (`1.0.1`) → phát hành như bình thường. Không bao giờ di chuyển một tag đã publish.
- **Thu hồi bản phát hành lỗi nghiêm trọng:** đánh dấu release là *pre-release* hoặc sửa mô tả để ghi rõ "Không dùng bản này; nâng cấp lên X.Y.Z+1". Không xoá release mà người dùng đã tải (link checksum và các bài viết sẽ bị hỏng).
- **Lộ certificate / API key:** thu hồi ngay trên developer.apple.com / App Store Connect, tạo cái mới, và cập nhật secret.

## 6. Bước tiếp theo

- **Cập nhật trong app** (Sparkle, với EdDSA key để ký bản cập nhật): chưa lên lịch; sẽ cần một ngoại lệ cho ADR-3 (không dependency ngoài) trong [ARCHITECTURE.vi.md](ARCHITECTURE.vi.md).
- **Homebrew cask**: bắt đầu với tap cá nhân; chuyển sang cask chính thức khi đủ người dùng.
