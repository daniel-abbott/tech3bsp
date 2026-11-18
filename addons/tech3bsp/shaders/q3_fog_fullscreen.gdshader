shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled, specular_disabled, fog_disabled;

// One pass after solid geometry. The view ray is reconstructed from the
// depth buffer and clipped to each fog brush. Untagged faces and the air
// in an opening pick up fog without a hull and without a per-surface shader.
uniform sampler2D depth_texture : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec4 t3_fs_info[32];
uniform float t3_fs_nplanes[32];
uniform vec4 t3_fs_planes[512];
uniform vec4 t3_fs_mins[32];
uniform vec4 t3_fs_maxs[32];
uniform int t3_fs_count = 0;

vec3 tech3_fs_color(vec3 c) {
	// fogparms are sRGB bytes. Compatibility writes framebuffers as sRGB;
	// Forward+ and Mobile want linear albedo.
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	return c;
	#else
	c = clamp(c, vec3(0.0), vec3(1.0));
	vec3 lo = c / 12.92;
	vec3 hi = pow((c + vec3(0.055)) / 1.055, vec3(2.4));
	return mix(hi, lo, lessThan(c, vec3(0.04045)));
	#endif
}

bool tech3_fs_box(vec3 bmin, vec3 bmax, vec3 eye, vec3 dir, float dist) {
	float t0 = 0.0;
	float t1 = dist;
	vec3 inv = vec3(
		abs(dir.x) > 0.000001 ? 1.0 / dir.x : 1.0e8,
		abs(dir.y) > 0.000001 ? 1.0 / dir.y : 1.0e8,
		abs(dir.z) > 0.000001 ? 1.0 / dir.z : 1.0e8
	);
	vec3 ta = (bmin - eye) * inv;
	vec3 tb = (bmax - eye) * inv;
	vec3 tmin = min(ta, tb);
	vec3 tmax = max(ta, tb);
	t0 = max(t0, max(tmin.x, max(tmin.y, tmin.z)));
	t1 = min(t1, min(tmax.x, min(tmax.y, tmax.z)));
	return t1 >= t0;
}

float tech3_fs_span(int base, int nplanes, vec3 eye, vec3 dir, float dist) {
	float t0 = 0.0;
	float t1 = dist;
	for (int i = 0; i < 16; i++) {
		if (i >= nplanes) {
			break;
		}
		vec4 pl = t3_fs_planes[base + i];
		float denom = dot(pl.xyz, dir);
		float pd = dot(pl.xyz, eye) - pl.w;
		if (abs(denom) < 0.000001) {
			if (pd > 0.001) {
				return 0.0;
			}
			continue;
		}
		float t = -pd / denom;
		if (denom > 0.0) {
			t1 = min(t1, t);
		} else {
			t0 = max(t0, t);
		}
	}
	return max(t1 - max(t0, 0.0), 0.0);
}

void vertex() {
	// UV holds the clip-space corner. The mesh itself is only an AABB so
	// the pass is not frustum-culled away from the origin.
	POSITION = vec4(UV, 1.0, 1.0);
}

void fragment() {
	float depth = texture(depth_texture, SCREEN_UV).r;
	// Compatibility NDC z is [-1, 1]. Forward+ and Mobile are reverse-z [0, 1].
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	#endif
	vec4 world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	world.xyz /= world.w;
	vec3 eye = INV_VIEW_MATRIX[3].xyz;
	vec3 delta = world.xyz - eye;
	float dist = length(delta);
	vec3 dir = dist > 0.0001 ? delta / dist : vec3(0.0, 0.0, 1.0);
	vec3 fog_rgb = vec3(0.0);
	float fog_a = 0.0;
	for (int v = 0; v < 32; v++) {
		if (v >= t3_fs_count) {
			break;
		}
		float depth_for_opaque = t3_fs_info[v].a;
		if (depth_for_opaque <= 0.0) {
			continue;
		}
		if (!tech3_fs_box(t3_fs_mins[v].xyz, t3_fs_maxs[v].xyz, eye, dir, dist)) {
			continue;
		}
		int nplanes = int(t3_fs_nplanes[v]);
		float span = tech3_fs_span(v * 16, nplanes, eye, dir, dist);
		// Fog image is sqrt(distance/depthForOpaque). The /8 in tcScale
		// made this thinner than Q3; *8 made it opaque at depth/8.
		float s = span / depth_for_opaque;
		float a = sqrt(clamp(s, 0.0, 1.0));
		if (a <= 0.0) {
			continue;
		}
		vec3 col = tech3_fs_color(t3_fs_info[v].rgb);
		fog_rgb += col * a * (1.0 - fog_a);
		fog_a += a * (1.0 - fog_a);
		if (fog_a > 0.98) {
			break;
		}
	}
	ALBEDO = fog_a > 0.0001 ? fog_rgb / fog_a : vec3(0.0);
	ALPHA = fog_a;
}
