# Courseflow (课序)

A native SwiftUI coursework tracker for macOS, iOS and iPadOS. It keeps a term's courses, assignments, deadlines, exams and course materials in one local app, separates *course facts* (what the course says) from *personal progress* (what you have done), and takes updates as versioned JSON packages instead of scraping any platform.

Built for my own Berkeley term in autumn 2026 and used daily; shared as-is. No account, no cloud, no telemetry.

## What it does

- Three-pane layout on the Mac, tab bar on iPhone, adaptive split view on iPad; system Liquid Glass controls; light, dark and system appearance.
- Today view, date-ordered schedule, exam schedule and a month calendar; official due dates, page-close times and personal plans are kept apart. Course filter, to-do-only filter and search.
- Per-course overview, materials and assignments. Each assignment links to its requirements, its materials and the exact platform page.
- Built-in readers for PDF, images, Markdown and Jupyter notebooks (zoom, outline for long documents, PDF search, export of the original file); local copies and Quick Look for attachments.
- Deliverable checklists per assignment, grading follow-up states (submitted, awaiting, partial, graded, feedback to review), an instructor-feedback inbox, personal plans and notes.
- Optional connection to a local course folder, so materials open from their original files; the app never moves or rewrites them.
- Course update packages: preview before import, idempotent re-imports, older revisions rejected, personal progress never overwritten. The rules are in [Docs/DATA-CONTRACT.md](Docs/DATA-CONTRACT.md).
- Export of the whole library and progress as JSON.
- Storage is SwiftData inside the app sandbox; the `--qa` launch flag uses a separate library for testing.

## Not implemented

iCloud sync, notifications, widgets, automatic course-platform scraping, school-account login, drag and drop, App Store distribution.

## Build

Requirements: Xcode 26 and Swift 6.2; macOS 26 for the Mac target, iOS/iPadOS 26 for the mobile targets.

- Open `Courseflow.xcodeproj`, pick the shared `Courseflow` scheme and a destination.
- Command line (ad-hoc signed Debug build under `~/Library/Caches`): `zsh Scripts/build-mac.sh`
- Tests of the core library, which has no UI dependencies:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Optional local seed data (`App/Resources/berkeley-fall-2026.json`, `App/Resources/course-library.json`, `App/Resources/StudyFiles/`) is git-ignored. Without it the app starts with an empty library and imports packages from Settings. `Scripts/package-study-library.py` builds the offline study library from a local course folder; adjust its folder map for your own courses.

## Layout

- `App/` SwiftUI app target: views, library store, file readers, calendar.
- `Sources/CourseflowCore/` models, calendar schedule, import engine, workspace catalog and IO.
- `Tests/CourseflowCoreTests/` XCTest coverage of the core library.
- `Scripts/` build, icon rendering, colour verification, QA-app preparation and the study-library packager.
- `Docs/` the data contract for update packages and the usability goals.

## 中文

课序是一个原生 SwiftUI 的课程作业追踪器（macOS / iOS / iPadOS）：课程、作业、截止日期、考试和课程资料放在本地一个 App 里，课程事实和个人进度分开保存，更新通过带版本号的 JSON 包导入，不抓取任何平台。个人课程数据不在仓库里。

## License

MIT
