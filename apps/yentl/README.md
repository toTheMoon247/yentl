# Yentl

The public consumer iOS app. SwiftUI.

## Creating the Xcode project

The `.xcodeproj` is not yet created. To set it up:

1. Open Xcode.
2. **File → New → Project**.
3. Select **App** under iOS.
4. Settings:
   - Product Name: `Yentl`
   - Team: your Apple Developer team (skip if you don't have one yet)
   - Organization Identifier: `com.yentl`
   - Bundle Identifier: `com.yentl.app` (Xcode auto-fills `com.yentl.Yentl` — override to `com.yentl.app` so the matchmaker app can use `com.yentl.matchmaker`)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage: **None** (Supabase is the backend)
   - Include Tests: **yes**
5. Save it inside this directory (`apps/yentl/`). Do **not** create a new git repo when prompted.
6. In the project settings, set **iOS Deployment Target** to **17.0**.
7. Display name on the iOS home screen: leave as `Yentl` (already matches the product name).
8. Add the shared package as a local dependency:
   - **File → Add Package Dependencies → Add Local…**
   - Select the `shared/` folder at the repo root.
   - Add the `YentlShared` library to the `Yentl` target.
9. Commit the generated `Yentl.xcodeproj` and source files.

After step 9 the app is ready for Phase 1 work.
