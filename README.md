# DeviceBrush 3D

**Like [Google's Just a Line](https://github.com/googlecreativelab/justaline-ios), DeviceBrush 3D lets you draw in 3D space with AR. It changes the interaction by placing a virtual brush tip beyond the device's upper-left corner, and refines the drawing experience with editable lines, merged vertices, colored faces, and pencil-style strokes.**

Turn your phone or tablet into a 3D brush: move the device itself to shape your drawing. **The current implementation targets iPad; iPhone and Android support are not implemented in this repository.** Built with SwiftUI, ARKit, and SceneKit, it tracks ordinary surroundings through the rear camera without printed markers.

English | [简体中文](docs/README.zh-CN.md)

[![Build iPad App](https://github.com/JadeJiang04/DeviceBrush3D/actions/workflows/build-ipad.yml/badge.svg)](https://github.com/JadeJiang04/DeviceBrush3D/actions/workflows/build-ipad.yml)

> Experimental prototype. The drawing sources have run in Swift Playground on an iPad. A native cloud build succeeded on November 24, 2026, with all 63 geometry checks passing and the IPA checksum verified. **Signing, installation, and native full-screen behavior still need device verification.** The workflow produces an unsigned IPA, which cannot be installed directly.

## Drawing tools

| Feature | How it works |
| --- | --- |
| Device-corner brush | Draw from a virtual extension of the upper-left corner; an orange crosshair marks its projected position. |
| Continuous strokes | Hold the draw button, move the device, and release to finish. |
| Simplified paths | Reduce strokes to 3D polylines while preserving distinct corners; only the two endpoints appear as editable vertices. |
| Two-point lines | Capture a start and an end to create a straight segment. |
| Colors and strokes | Choose seven colors, pencil grain or solid strokes, and an adjustable continuous-stroke width. |
| Geometry editing | Add a segment from a vertex using a direction and length; resize, shorten, or align geometry horizontally or to an axis. |
| Vertices and faces | Manually merge two vertices or create a colored triangle from three non-collinear vertices. |
| Compact controls | Collapse the lower-right tool panel and the draggable editing panel. |
| JSON export | Save vertices, segments, paths, triangular faces, and coordinate-frame metadata. |

## Start drawing

The current app interface is in Chinese; the labels below help you find each control.

1. Allow camera access. Point the rear camera at a well-lit, textured surface and move slowly until tracking is ready (`已定位`).
2. Keep Device Brush (`设备画笔`) selected and check the orange crosshair. Adjust the corner extension and forward offset in settings as needed.
3. Hold the draw button, move the device, and release. Alternatively, expand the tools and choose Two-point Line (`两点直线`).
4. Open Edit (`编辑`) to select vertices, adjust lengths, or create colored faces. Internal bends are not exposed as selectable vertices.
5. Expand the tool panel and scroll to Export (`导出`) to save a drawing as JSON.

While idle, the tip follows the upper-left corner of the current screen orientation. During a stroke or two-point capture, it stays attached to the same physical corner to avoid a sudden tip change.

### Coordinates and lengths

- Tracking uses ARKit camera poses, rather than a custom double integration of accelerometer readings.
- The user coordinate frame is right-handed: **X/Y are horizontal and Z points up**. Two existing vertices can define the origin and +X direction.
- Stroke simplification defaults to **3 mm**, adjustable from 1–10 mm for new strokes. This is a geometry tolerance, **not measurement accuracy**.
- Path length follows the simplified polyline. Setting a target length scales the path around its first point; shortening trims it from the tail along the path.
- `paths.points` stores current geometry; `paths.rawPoints` retains the original samples even after edits.
- The default virtual tip extends 0.5 cm beyond the corner and 8 cm forward toward the scene. It is not a contact probe on the device body.

## Device support and limitations

The tested device is an **11-inch iPad Pro (4th generation), iPad14,3**. Only this model currently has a built-in body and camera dimension preset; other models require manual offsets. The native target is iPad-only, requires ARKit, and has a minimum deployment target of iPadOS 16. Other devices have not been verified.

- Tip offsets are estimated from device drawings and have not been physically calibrated. Centimeter or millimeter measurement accuracy is not guaranteed.
- Reflections, low texture, poor lighting, occlusion, and fast movement can degrade tracking. Tracking interruptions or large jumps end the current stroke.
- Faces are manually created triangles, not automatic fills for arbitrary closed strokes.
- Capture pauses while the editor is open; close it to resume drawing.
- Restarting begins a new AR session. JSON preserves geometry, but ARWorldMap persistence and scene restoration are not implemented.
- The native app is configured for full-screen use, pending a signed installation test. The Playground version remains constrained by its host interface.

## Repository layout

```text
Sources/
  SpatialPenApp.swift            Native app entry point
  ContentView.swift              Camera overlay, tools, and settings
  ARMeasurementController.swift AR tracking, capture, undo, and export
  MeasurementModel.swift        UI state, device presets, and tip offsets
  DrawingGeometry.swift         Geometry, simplification, and shared-vertex editing
  GeometryEditorView.swift       Vertex, length, axis, and face controls
  StrokeRendering.swift         3D pencil strokes and press-and-hold input
Tests/main.swift                63 geometry and sampling checks
docs/README.zh-CN.md             Chinese documentation
scripts/build-ios.sh            Shared local and CI build script
project.yml                     XcodeGen project definition
.github/workflows/build-ipad.yml Manual macOS build workflow
```

The public project name is **DeviceBrush 3D**. Internal target, scheme, and data filenames retain `SpatialPen` for continuity with the existing prototype.

## Build

### GitHub Actions, including from Windows

1. Open **Actions → Build iPad App → Run workflow** in this repository.
2. The macOS runner executes geometry checks and builds the device app with Xcode.
3. Download the `SpatialPen-unsigned` artifact to obtain `SpatialPen-unsigned.ipa` and `SHA256SUMS.txt`.
4. Sign the app with your own Apple signing identity before installing it. The workflow itself does not need Apple credentials, certificates, or device pairing files.

The workflow runs only on manual request, has a 20-minute timeout, and retains artifacts for three days. As checked on November 24, 2026, **this public repository's standard `macos-15` runner has free compute usage**. Private repositories use plan allowances; larger runners can incur charges even in public repositories. Artifact and cache storage have separate allowances and billing rules. See [GitHub Actions billing and usage](https://docs.github.com/en/actions/concepts/billing-and-usage) and [storage and paid usage details](https://docs.github.com/en/billing/concepts/product-billing/github-actions). These are cloud-build costs, separate from Apple signing or distribution requirements.

### On a Mac

Install Xcode and its command-line tools, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen), then run:

```bash
bash scripts/build-ios.sh
```

The output is `output/SpatialPen-unsigned.ipa`. To sign and run through Xcode, open the generated `SpatialPen.xcodeproj`, set `CODE_SIGNING_ALLOWED` to `YES`, and select your development team. Signing is disabled by default.

To run only the geometry checks:

```bash
mkdir -p build
xcrun swiftc Sources/DrawingGeometry.swift Tests/main.swift -o build/geometry-checks
./build/geometry-checks
```

The checks cover simplification, error bounds, coordinate calibration, length edits, shared endpoints, rollback of invalid operations, and JSON round trips. All 63 checks have passed on iPad and in the native cloud build. They do not replace physical validation of movement distances and tip placement.

## References

- [Google Creative Lab · Just a Line iOS](https://github.com/googlecreativelab/justaline-ios): a reference for AR line drawing and rendering; its source is not bundled in this repository.
- [Apple · 11-inch iPad Pro (4th generation) dimensional drawings](https://developer.apple.com/download/files/accessories/dimensional-drawings/ipad-pro-11-inch-4th-generation.pdf): used to estimate body and camera positions.
- [Apple · ARCamera.transform](https://developer.apple.com/documentation/arkit/arcamera/transform): camera pose and device coordinate conventions.

## License

[MIT License](LICENSE). Use, modification, redistribution, and commercial use are permitted with the copyright and license notice retained. The software is provided as is, without a promise of measurement accuracy or fitness for a particular purpose.

Maintained by [JadeJiang04](https://github.com/JadeJiang04).
