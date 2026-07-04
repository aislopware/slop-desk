// CanvasTextureShader — the terminal canvas's MATERIAL finish (visible-design pass, 2026-07-04):
// static film grain + a soft edge vignette as a libghostty custom shader.
//
// Why: a flat colour field reads as "CSS swatch" in a static screenshot; a few percent of fixed
// per-pixel grain turns it into a coated material, and a gentle edge darkening pulls the eye to the
// centre and reinforces the pane card's rounded silhouette. Both effects are deliberately STATIC —
// the grain hash keys on `fragCoord` only (NO `iTime`), so nothing ever shimmers or costs a
// continuous render loop; this is texture, not animation.
//
// Delivery mirrors ``CursorTrailShader`` exactly: the GLSL ships as a Swift string, materializes
// idempotently to Application Support under a VERSIONED filename, and ``TerminalConfigBuilder``
// emits a second `custom-shader = <path>` line (ghostty's `custom-shader` is a `RepeatablePath` —
// passes chain in order, and this pass is emitted AFTER the cursor trail so the grain also textures
// the smear, one consistent film over everything). Materialization failure ⇒ `nil` ⇒ no line
// (validate-then-drop; the canvas is simply flat).

import Foundation

public enum CanvasTextureShader {
    /// Bump when ``source`` changes — the materialized filename carries it, so an updated shader never
    /// fights a stale cached copy.
    public static let version = 1

    /// The GLSL (Shadertoy-dialect) source. Taste knobs are the two consts: `GRAIN_STRENGTH` (the
    /// daily-driver band is 0.02–0.05; past ~0.08 it reads as dirt) and `VIGNETTE_STRENGTH` (edge
    /// darkening cap; past ~0.2 it reads as a hole).
    public static let source = """
    // Aislopdesk canvas texture (visible-design pass, 2026-07-04).
    // STATIC film grain + edge vignette. No time uniform anywhere — fixed per-pixel, never shimmers.

    float hash12(vec2 p) {
        vec3 p3 = fract(vec3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord.xy / iResolution.xy;
        vec4 color = texture(iChannel0, uv);

        const float GRAIN_STRENGTH = 0.030;    // ± band around the source pixel
        const float VIGNETTE_STRENGTH = 0.10;  // max edge darkening
        const float VIGNETTE_INNER = 0.62;     // where the falloff starts (normalized radius)
        const float VIGNETTE_OUTER = 1.30;     // where it peaks (past the corners: soft, never a ring)

        // Symmetric grain: a fixed hash per pixel, centred on 0 so the mean brightness is untouched.
        color.rgb += (hash12(fragCoord.xy) - 0.5) * GRAIN_STRENGTH;

        // Elliptical vignette: distance from centre in aspect-corrected halves, eased between the
        // inner/outer radii. The card's rounded corners sit right where the falloff lands.
        vec2 centered = (uv - 0.5) * 2.0;
        float edge = smoothstep(VIGNETTE_INNER, VIGNETTE_OUTER, length(centered));
        color.rgb *= 1.0 - VIGNETTE_STRENGTH * edge;

        fragColor = vec4(clamp(color.rgb, 0.0, 1.0), color.a);
    }
    """

    /// Writes ``source`` to Application Support (idempotent — skips the write when the versioned file
    /// already exists) and returns its absolute path, or `nil` when the filesystem refuses (the caller
    /// then emits no `custom-shader` line — the canvas is simply flat).
    public static func materializedPath(fileManager: FileManager = .default) -> String? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("Aislopdesk/shaders", isDirectory: true)
        let file = dir.appendingPathComponent("canvas-texture-v\(version).glsl")
        if fileManager.fileExists(atPath: file.path) { return file.path }
        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            try source.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch {
            return nil
        }
    }
}
