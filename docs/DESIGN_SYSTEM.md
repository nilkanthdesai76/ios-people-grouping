# DESIGN_SYSTEM.md

Native iOS look: system materials, SF Pro, SF Symbols, light and dark from system colors. No custom fonts, no hard-coded black or white. Goal is a clean Apple Photos feel, not a brand.

## 1. Colour (system semantic only)
- Accent: `Color.accentColor` (set in `Assets.xcassets/AccentColor`, choose a calm blue `#0A84FF`).
- Backgrounds: `Color(.systemBackground)`, grouped lists `Color(.systemGroupedBackground)`, cards `Color(.secondarySystemGroupedBackground)`.
- Text: `.primary`, `.secondary`. Warnings: `.orange`. Destructive: `.red`.
- Face-box overlay stroke: `.yellow`, 2 pt.

## 2. Typography (Dynamic Type always on)
- Screen title: `.largeTitle.bold()`; section header: `.headline`; person name: `.subheadline.weight(.semibold)`; count/caption: `.caption` + `.secondary`; stats numbers: `.title2.monospacedDigit()`.
- Never use fixed font sizes.

## 3. Spacing, shape, targets
- Spacing scale 4 / 8 / 12 / 16 / 24. Screen margin 16.
- People grid: adaptive columns, minimum 104 pt, spacing 16; cover is a circle (`Circle()` clip) with 1 pt `.separator` stroke.
- Photo grid: 3 columns, spacing 2, square cells, no corner radius (like Photos).
- Cards 16 pt radius. Minimum tap target 44 x 44.

## 4. Screens
1. **Permission**: icon (`person.2.crop.square.stack`), two-line explanation, primary button "Allow Photos Access"; denied state shows "Open Settings".
2. **People tab**: grid of people; header chip "Other faces: N"; toolbar: Select (merge) button; empty state "Scan your library to find people".
3. **Person detail**: large circular cover, editable name (tap to rename), "N photos", 3-column photo grid; menu: Merge into..., Hide person; long-press a photo: "Not this person".
4. **Photo viewer**: full-screen photo, face boxes overlay, name labels under boxes.
5. **Scan tab**: progress ring + counts (scanned / total, faces, people), Start / Pause / Resume button, thermal notice.
6. **Settings**: match threshold slider with live value, Re-cluster, Rescan all, Reset all data, Diagnostics section (see docs/TESTING.md), banner when the fallback embedder is active.

## 5. Motion and a11y
Standard SwiftUI transitions only; respect Reduce Motion. Every image and button gets an accessibility label (e.g. "Person: Unnamed, 42 photos").
