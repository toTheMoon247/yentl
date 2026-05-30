# Yentl Matchmaker

The internal iOS app for matchmakers. SwiftUI. Not for public App Store distribution at MVP.

## Creating the Xcode project

The `.xcodeproj` is not yet created. To set it up:

1. Open Xcode.
2. **File → New → Project**.
3. Select **App** under iOS.
4. Settings:
   - Product Name: `YentlMatchmaker` (no space — Xcode product names cannot contain spaces)
   - Team: your Apple Developer team (skip if you don't have one yet)
   - Organization Identifier: `com.yentl`
   - Bundle Identifier: `com.yentl.matchmaker` (Xcode auto-fills `com.yentl.YentlMatchmaker` — override to `com.yentl.matchmaker` so it stays symmetric with the consumer app's `com.yentl.app`)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None** (Supabase is the backend)
   - Include Tests: **yes**
5. Save it inside this directory (`apps/yentl-matchmaker/`). Do **not** create a new git repo when prompted.
6. In the project settings, set **iOS Deployment Target** to **17.0**.
7. Set **Display Name** (Info.plist → `CFBundleDisplayName`) to `Yentl Matchmaker` (with the space) so users see "Yentl Matchmaker" on the iOS home screen instead of "YentlMatchmaker".
8. Add the shared package as a local dependency:
   - **File → Add Package Dependencies → Add Local…**
   - Select the `shared/` folder at the repo root.
   - Add the `YentlShared` library to the `YentlMatchmaker` target.
9. Commit the generated `YentlMatchmaker.xcodeproj` and source files.

After step 9 the app is ready for Phase 1 work.
