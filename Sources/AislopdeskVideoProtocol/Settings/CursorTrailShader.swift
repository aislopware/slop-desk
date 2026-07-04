// CursorTrailShader — the Neovide-style cursor motion trail as a libghostty CUSTOM SHADER (design-craft
// pass, 2026-07-04). Ghostty 1.2 exposes the cursor's current/previous pixel rect + the change timestamp
// to `custom-shader` post-process shaders (`iCurrentCursor` / `iPreviousCursor` / `iTimeCursorChange`,
// computed in the shared Zig renderer and live on the Metal backend of our pinned fork) — so the smear
// needs ZERO Swift-side cursor plumbing and no vendor patch: the whole effect is this one GLSL file,
// referenced by a `custom-shader = <path>` config line (``TerminalConfigBuilder``).
//
// The motion is deliberately CRITICALLY-DAMPED in feel (the Neovide rule — springy overshoot is what
// tips a cursor trail into gimmick): the leading edge reaches the target on a fast quintic ease-out
// while the tail lags on a smoothstep, and the smear is the capsule between them, fading over its
// lifetime. The single most important taste knob is the JUMP gate: the trail draws ONLY when the cursor
// jumps ≥ 1.5× its own size — same-cell/next-cell typing never smears (the keystroke-frequency rule;
// the same `DRAW_THRESHOLD` idiom the reference cursor_blaze shader ships).
//
// The shader ships as a Swift string and is MATERIALIZED to Application Support on demand (idempotent,
// versioned filename — bump `version` when `source` changes so stale copies are superseded); libghostty
// only accepts a filesystem path. Materialization failure ⇒ `nil` ⇒ the config line is skipped
// (validate-then-drop; the terminal just has no trail).

import Foundation

public enum CursorTrailShader {
    /// Bump when ``source`` changes — the materialized filename carries it, so an updated shader never
    /// fights a stale cached copy.
    public static let version = 1

    /// The GLSL (Shadertoy-dialect) source. Coordinate contract (Metal backend, `y_is_down`):
    /// `iCurrentCursor.xy` = the cursor glyph's LEFT/BOTTOM edge in pixels (y grows downward), `.zw` =
    /// width/height — the rect spans x ∈ [x, x+w], y ∈ [y−h, y].
    public static let source = """
    // Aislopdesk cursor motion trail (design-craft pass, 2026-07-04).
    // Critically-damped smear between the previous and current cursor rects; draws ONLY on jumps
    // ≥ JUMP_THRESHOLD × cursor size, fades over DURATION. See CursorTrailShader.swift for the contract.

    float sdSegment(vec2 p, vec2 a, vec2 b) {
        vec2 pa = p - a, ba = b - a;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
        return length(pa - ba * h);
    }

    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord.xy / iResolution.xy;
        fragColor = texture(iChannel0, uv);

        const float DURATION = 0.22;       // trail lifetime, seconds
        const float MAX_ALPHA = 0.35;      // peak trail opacity
        const float JUMP_THRESHOLD = 1.5;  // × cursor size — typing never smears, only real jumps

        if (iCursorVisible == 0) { return; }
        float p = (iTime - iTimeCursorChange) / DURATION;
        if (p <= 0.0 || p >= 1.0) { return; }

        // Cursor rect centres (Metal y-down: .xy is the LEFT/BOTTOM edge, so the centre is y - h/2).
        vec2 curC = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5,
                         iCurrentCursor.y - iCurrentCursor.w * 0.5);
        vec2 prevC = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5,
                          iPreviousCursor.y - iPreviousCursor.w * 0.5);

        float gate = JUMP_THRESHOLD * max(iCurrentCursor.z, iCurrentCursor.w);
        if (length(curC - prevC) < gate) { return; }

        // Critically-damped feel: the LEADING edge arrives fast (quintic ease-out), the TAIL lags
        // (smoothstep) — the capsule between them is the smear. No overshoot by construction.
        float lead = 1.0 - pow(1.0 - p, 5.0);
        float tail = p * p * (3.0 - 2.0 * p);
        vec2 leadPos = mix(prevC, curC, lead);
        vec2 tailPos = mix(prevC, curC, tail);

        float radius = 0.5 * min(iCurrentCursor.z, iCurrentCursor.w);
        float d = sdSegment(fragCoord.xy, tailPos, leadPos) - radius;

        // Fade over the trail's life, thin toward the tail, 1px anti-aliased edge.
        float span = max(dot(leadPos - tailPos, leadPos - tailPos), 1e-4);
        float along = clamp(dot(fragCoord.xy - tailPos, leadPos - tailPos) / span, 0.0, 1.0);
        float alpha = MAX_ALPHA * (1.0 - p) * mix(0.4, 1.0, along) * (1.0 - smoothstep(-1.0, 1.0, d));

        // The cursor's own colour; fall back to the theme cursor colour when the style ships alpha 0.
        vec3 trailColor = mix(iCursorColor, iCurrentCursorColor.rgb, step(0.01, iCurrentCursorColor.a));
        fragColor.rgb = mix(fragColor.rgb, trailColor, alpha);
    }
    """

    /// Writes ``source`` to Application Support (idempotent — skips the write when the versioned file
    /// already exists) and returns its absolute path, or `nil` when the filesystem refuses (the caller
    /// then emits no `custom-shader` line — the terminal simply has no trail).
    public static func materializedPath(fileManager: FileManager = .default) -> String? {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("Aislopdesk/shaders", isDirectory: true)
        let file = dir.appendingPathComponent("cursor-trail-v\(version).glsl")
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
