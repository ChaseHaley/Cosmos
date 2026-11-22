package motion

import "core:math"

// A timing curve. A Bézier's p is x1, y1, x2, y2 with x within 0..1 and y within -1..2, so it can
// overshoot; a spring's p[0] is its bounce, 0..0.9.
Curve :: struct {
	spring: bool,
	p:      [4]f32,
}

Named_Curve :: struct {
	name:  string,
	curve: Curve,
}

// The family's named curves. Their names are reserved: an app's own curves cannot take them.
BUILTIN_CURVES :: [?]Named_Curve {
	{"linear", {p = {0, 0, 1, 1}}},
	{"decelerate", {p = {0.2, 0, 0, 1}}},
	{"accelerate", {p = {0.4, 0, 1, 1}}},
	{"smooth", {p = {0.4, 0, 0.2, 1}}},
	{"quick", {p = {0.15, 0, 0.1, 1}}},
	{"overshot", {p = {0.05, 0.9, 0.1, 1.1}}},
	{"back", {p = {0.34, 1.56, 0.64, 1}}},
	{"spring", {spring = true, p = {0.2, 0, 0, 0}}},
	{"wobbly", {spring = true, p = {0.5, 0, 0, 0}}},
}

// How an entering or leaving item appears. Edge grows it from, or collapses it into, the side it shares
// with its neighbour.
Effect :: enum u8 {
	Edge,
	Pop,
	Fade,
	Slide,
}

// A spring's natural frequency in radians over the whole motion: about 1.4 oscillations, so even a
// bouncy spring has settled by the time the duration ends.
@(private)
SPRING_FREQUENCY :: 2 * math.PI * 1.4
// The least damping a spring keeps, so the largest bounce still settles.
@(private)
SPRING_DAMPING_MINIMUM :: 0.08

// Progress along `c` at time t in 0..1: 0 at the start, exactly 1 from the end on, and free to leave
// 0..1 between them where the curve overshoots.
ease :: proc(c: Curve, t: f32) -> f32 {
	if t <= 0 {return 0}
	if t >= 1 {return 1}
	if c.spring {
		w: f32 = SPRING_FREQUENCY
		z := max(SPRING_DAMPING_MINIMUM, 1 - c.p[0])
		if z >= 1 {return 1 - math.exp(-w * t) * (1 + w * t)}
		wd := w * math.sqrt(1 - z * z)
		return 1 - math.exp(-z * w * t) * (math.cos(wd * t) + (z * w / wd) * math.sin(wd * t))
	}
	// Control points on the diagonal make y equal x: the curve is linear, exactly.
	if c.p[0] == c.p[1] && c.p[2] == c.p[3] {return t}
	// With both x control points within 0..1, x rises with u, so bisection finds the one u where
	// x(u) = t.
	low, high: f32 = 0, 1
	for _ in 0 ..< 24 {
		u := (low + high) / 2
		if bezier(c.p[0], c.p[2], u) < t {low = u} else {high = u}
	}
	return bezier(c.p[1], c.p[3], (low + high) / 2)
}

// One coordinate of a cubic Bézier from (0, 0) to (1, 1) with control coordinates a and b.
@(private)
bezier :: proc(a, b, u: f32) -> f32 {
	v := 1 - u
	return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
}
