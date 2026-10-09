# Burro mascots

The selected identity is **Butter**. **Abstract** is an alternate concept.

Both are solid white with transparent eye cutouts, designed for Burro's black and charcoal surfaces. `comparison.png` shows the two marks together and at actual 18, 22, and 32 point sizes. The standalone PNG and SVG exports have transparent backgrounds.

The built-in image-generation tool produced initial concepts using the prompts below. Those raster drafts had rough alpha edges; the final artwork is an original native vector implementation in `script/generate_brand.swift`. It exports the two production PDFs to `Sources/Burro/Resources/Brand` and the PNG/SVG previews here. No generated draft bitmap is used by the app.

Regenerate from the repository root with `swift script/generate_brand.swift`. The normal build script generates the Dock/Finder icon from the same butter PDF. Menu-bar rendering uses the native template tint; the notch uses white at its existing 22-point frame.

The expanded notch and agent avatars use separate `butter-body.pdf` and `butter-plate.pdf` layers, with `butter-eyes.json` as an animated transparent mask. The butter hops off its stationary wrapper, squashes on landing, double bounces, tilts, glances, and blinks within the original compact frame. Claude avatars are orange and Codex avatars blue, with stable timing offsets so they do not move together. Idle agents have quieter motion; stale agents stay still. Core Animation renders the motion without per-frame app updates. Collapsed/hidden views and Reduce Motion show a still mascot; the menu bar and Dock remain static.

## Initial concept prompts — built-in image generation

### Butter

Use case: logo-brand. Asset type: production transparent mascot icon for Burro, a compact native macOS app with a black/charcoal background. Create ONE minimal white butter mascot: a small softly rounded butter pat seen as a gently slanted chunky slab, with an extremely simple folded paper cradle implied by just one bold lower silhouette. Friendly and quietly clever, Apple-quality restraint. Two tiny transparent oval eye cutouts in the front face, no mouth, arms, legs, text, decorations, plate, or sparkles. The overall contour must feel distinctive, balanced, and beautiful at 18–22 pixels. Flat solid pure white shapes only, negative-space cutouts, thick forms and very few details. No gray, shading, gradients, lighting, outlines, 3D rendering, or shadows. A single isolated mark centered on a genuinely transparent square canvas, occupying about 85% of the canvas width and 70% height; preserve transparent padding. Do not include an app tile, black background, text, labels, variants, mockup, or contact sheet.

### Abstract

Use case: logo-brand. Asset type: production transparent mascot icon for Burro, a compact native macOS app with a black/charcoal background. Create ONE original abstract white mascot. A quiet friendly little pebble-like creature: squat soft asymmetric silhouette, a gently sloped domed top with one subtle off-center fold/notch, two tiny transparent oval eye cutouts, a broad softly irregular lower edge suggesting two tiny feet without separate limbs. Calm, clever and understated. Distinctive sculptural silhouette rather than a generic ghost, cloud, cat, robot, or bunny. Balanced, sophisticated, with Apple-like graphic restraint. Designed to read immediately at 18–22 pixels, with bold simple shapes and generous negative space. Flat solid pure white only and transparent negative-space eyes; no gray, shading, gradients, lighting, stroke outlines, 3D rendering, shadows, mouth, arms, accessories, text, sparkles, or decorations. Single isolated mark centered on genuinely transparent square canvas, occupying about 80% of its width and 80% height. No app tile, black background, labels, variants, mockup, or contact sheet.
