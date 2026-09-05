# iOS TestFlight Checklist

1. Confirm `apps/ios/project.yml` bundle ID/version/build settings are correct.
2. Build/archive in Xcode from `apps/ios/Litter.xcodeproj`.
3. Update `docs/releases/testflight-whats-new.md` with changelog bullets for this build.
4. Upload via `./apps/ios/scripts/testflight-upload.sh` (script auto-applies What to Test notes, assigns internal and external beta groups, submits Beta App Review by default, and auto-bumps to the next patch version if the committed repo version has already shipped live).
5. Validate processing in App Store Connect.
6. Confirm the build is attached to both internal and external TestFlight groups.
7. Confirm Beta App Review submission/approval state for the external build, then verify release notes and tester instructions.
8. If the workflow advanced to a new beta patch version, confirm `apps/ios/project.yml` and `docs/releases/testflight-whats-new.md` were updated for the next cycle.
9. Smoke test install + login/session/message flow.

## Automatic internal releases

Every push to `main` starts `.github/workflows/ios-testflight.yml`. It builds the
pushed commit with Xcode 26.6, allocates the next App Store Connect build number,
uploads it, waits for processing, and assigns it to **Internal Testers**. It does
not submit external Beta App Review. You can also run it manually in GitHub
Actions and choose the beta groups.

Releases run one at a time. An active upload finishes; if several commits arrive
while it runs, GitHub keeps the newest pending release. The workflow never commits
version changes back to `main`. Release logs and build metadata are retained as
GitHub Actions artifacts for 14 days.

Repository secrets required:

- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_P8_B64`
- `IOS_DIST_CERT_P12_B64`, `IOS_DIST_CERT_PASSWORD`
- `IOS_APP_STORE_PROFILE_B64`, `IOS_LIVE_ACTIVITY_APP_STORE_PROFILE_B64`
- `IOS_WATCH_APP_STORE_PROFILE_B64`, `IOS_WATCH_COMP_APP_STORE_PROFILE_B64`

The certificate and profiles must cover team `UF4L3PL7UG`, app
`com.chirag.learnfold`, and its live activity, Watch app, and Watch complication
extensions. Renew these secrets before the signing assets expire. The current
profiles expire on April 29, 2027. Hosted beta access is provisioned per installation;
no shared Hosted token belongs in the app or workflow secrets.
