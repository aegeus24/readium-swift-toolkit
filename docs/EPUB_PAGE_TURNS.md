# Native EPUB page turns

The fork adds `EPUBNavigatorViewController.pageTurnStyle`: slide (default), curl, and instant. Vertical scrolling/text retain their renderer. Reduce Motion skips curls. Active text selection disables interactive curl input; native tap recognizers are disabled so Readium continues to filter interactive HTML and dispatch edge taps.

## Interactive dragging

Curl mode prepares current and adjacent viewport images using one short-lived preview navigator with no application delegate and no neighboring resource preloads. It never navigates the live publication during preparation. At most three spread images are retained by the interactive cache; preview views are removed after preparation and immediately on invalidation. Snapshot textures are bounded by the existing capture path.

A native UIPageViewController uses these snapshots as its data source. Its public gesture recognizers are attached to the containing navigator view. Live HTML sits above the raster controller at rest, retaining links, selection and accessibility. Once a native transition starts, the raster surfaces move above live HTML and follow UIKit's finger-tracked page curl, including pause, reversal and cancellation. Two columns use separate physical halves with a middle spine; one column uses a minimum spine. Adjacent controllers are mapped by physical side, independent of reading direction.

Cancellation reveals the unchanged live renderer. Only `transitionCompleted` commits one corresponding live Readium move; the snapshot remains above it while that move finishes. Invalidated/duplicate callbacks cannot commit another page. Rotation, view resizing, settings changes, disappearance and direct locator jumps invalidate pending previews and native curl surfaces. A new cache is prepared after the current location settles. A drag requires prepared neighboring snapshots; navigation buttons and edge taps remain available during preparation.

## Programmatic navigation

Buttons and edge taps keep the before/after snapshot animation. Their short-lived animation controllers are distinct from the idle interactive pager. Slide, instant, selection, links, semantic locators and TOC remain owned by Readium.

## Verification and limits

Mirrored app tests cover physical half images, native data-source adjacency, cancelled/completed transitions, duplicate and invalidated callbacks, and real WebKit navigation in one/two columns and LTR/RTL. Existing chapter crossings, programmatic curls and reflow tests remain relevant. Manual slow-drag, gesture arbitration around links/text selection and fold interruption still need physical-device validation. First-drag readiness, snapshot preparation latency and memory should be profiled with large publications. The upstream test script requires the generated TestApp project and xcbeautify; app-side mirrored tests do not imply a full upstream-suite pass.
