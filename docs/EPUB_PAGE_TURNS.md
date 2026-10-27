# Rolling native EPUB page turns

`EPUBNavigatorViewController.pageTurnStyle` offers slide, curl and instant. Curl uses a persistent UIPageViewController and a rolling viewport-image cache. Vertical scrolling/text, VoiceOver and Reduce Motion retain their existing non-curl paths.

## Visible pages and background synchronization

Native dragging, reversal and cancellation use the same pager throughout a reading run. A completed turn advances to its already-cached image immediately; the pager remains available for another cached turn while the live HTML renderer catches up. HTML navigation is serialized and coalesces to the latest completed destination. Cached images stay above HTML until it reaches the displayed page and its rendering is fenced with a WebKit snapshot. Live HTML then returns above the pager for links, selection and accessibility. Native tap recognizers are disabled; normal edge taps remain Readium's responsibility. During background synchronization a cache-surface edge tap can start another cached turn.

Completed cached destinations publish semantic locations immediately, so persistence does not wait for WebKit. Cancelled gestures publish nothing. Call `waitForPendingPageTurns()` before capturing text from the live renderer; `hasPendingPageTurns` indicates that it is behind. Locator jumps cancel/drain old synchronization before navigating elsewhere. Resizing, preferences and disappearance invalidate stale images and preserve the last completed cached destination. Duplicate/stale UIKit callbacks cannot navigate again. Failed synchronization rolls back to the last synchronized leaf.

Buttons and edge taps use cached native animation when their target is ready, with the old snapshot-animation fallback available when it is not. Invalidation resumes pending programmatic-animation callers even if UIKit omits its completion callback.

## Rolling window and memory

Default radius is **two spreads in each physical direction**, plus the current spread. In two-column mode each spread is two pages, so this buffers two complete page turns/four pages in each direction. Both physical halves remain printed native front/back leaves at a middle spine. Compact mode advances one logical page per turn and retains UIKit's native paper reverse.

One warm, noninteractive preview navigator, with no application delegate and zero resource preloads, renders missing edge images. It reuses loaded resources and prioritizes the nearest missing viewport in the reading direction. Existing images and the pager are not rebuilt on every turn. Offscreen WebViews can defer their animation-frame progress messages; cache positions are refreshed from the same DOM scroll coordinates used by Readium before pairing a locator with its image.

Images have a 1600-pixel longest dimension. The bitmap dictionary is capped at **64 MiB**, trimming farthest entries first while protecting the visible, pending and last-synchronized leaves. Normally there are five spread images; an older synchronized leaf can remain briefly protected during rapid turns. UIKit/GPU working surfaces and WebKit memory are additional, not included in that dictionary budget. A memory warning discards neighbors and the warm preview, preserving the visible/completing leaf. Refill resumes on user navigation. Fonts, themes, margins, layout, geometry and explicit jumps clear incompatible images.

Five spreads each way would retain eleven images before temporary surfaces and is not the default. Profile actual device latency and memory before raising the window.

## Verification

Mirrored app tests cover persistent pager identity, two rapid turns while the first HTML commit is suspended, cancellation, synchronization failure/rollback, duplicate/invalidated callbacks, programmatic cancellation, cache bounds and memory-pressure trimming. Live WebKit integration exercises immediate multi-turn display, forward/backward navigation, edge refill, LTR/RTL, middle/minimum spines and persisted positions. Bookmark and reflow callers wait for HTML synchronization before reading text anchors.

The upstream runner requires the generated TestApp project and xcbeautify; mirrored app tests do not imply a full upstream-suite pass. Physical slow-drag/fast-flip feel, gesture arbitration, fold interruption and memory profiling remain device checks.
