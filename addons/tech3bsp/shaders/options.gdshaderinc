// Options and functions for tech3 shaders.

// Driven by BSPScene.tech3_time so materials, skies, and styled OmniLights
// share one pausable clock. Must also exist under Project Settings
// Shader Globals (run "addons/tech3bsp/setup.gd").
// Opt in before the include:
//   #define TECH3_TIME      - global uniform tech3_time
//   #define TECH3_WAVE      - tech3_wave (sin/square/triangle/saw)
//   #define NOISE_LOOKUP    - tech3_noise + noise branch of tech3_wave
#ifdef TECH3_TIME
global uniform float tech3_time;
#endif

#define TEXTURE_FILTER filter_linear_mipmap_anisotropic

// Parallax. Normal samples are not gated by these.
// OFFSET_MAPPING: one height sample, UV shifted by the view ray.
// RELIEF_MAPPING: DarkPlaces 8+4 step march. Ignored unless OFFSET_MAPPING
// is true - a false offset define turns both off.
#define OFFSET_MAPPING false
#define RELIEF_MAPPING false

// tcGen environment. Only env-mapping passes emit tech3_env_uv() and call it.
//   0 = per vertex (Q3 / OpenArena: faceted, matches the engines)
//   1 = per pixel  (smoother fake reflections, closer to Source-style env)
#ifndef TECH3_ENV_PER_PIXEL
#define TECH3_ENV_PER_PIXEL 0
#endif

#ifdef NOISE_LOOKUP
// 256x1 RG float built by Tech3Noise.noise_texture():
//   R = table value, G = perm[i] as an exact integer stored in f32.
// Bound to the tech3_noise shader global from the plugin / BSPScene.
global uniform sampler2D tech3_noise : filter_nearest, repeat_disable;

vec2 tech3_noise_uv(int i) {
	return vec2((float(i & 255) + 0.5) / 256.0, 0.5);
}

int tech3_noise_val(int a) {
	return int(texture(tech3_noise, tech3_noise_uv(a)).g + 0.5);
}

float tech3_noise_lookup(int x, int y, int z, int t) {
	int idx = tech3_noise_val(x + tech3_noise_val(y + tech3_noise_val(z + tech3_noise_val(t))));
	return texture(tech3_noise, tech3_noise_uv(idx)).r;
}

float tech3_noise_get4f(float x, float y, float z, float t) {
	int ix = int(floor(x));
	float fx = x - float(ix);
	int iy = int(floor(y));
	float fy = y - float(iy);
	int iz = int(floor(z));
	float fz = z - float(iz);
	int it = int(floor(t));
	float ft = t - float(it);
	float value[2];
	for (int i = 0; i < 2; i++) {
		float front0 = tech3_noise_lookup(ix, iy, iz, it + i);
		float front1 = tech3_noise_lookup(ix + 1, iy, iz, it + i);
		float front2 = tech3_noise_lookup(ix, iy + 1, iz, it + i);
		float front3 = tech3_noise_lookup(ix + 1, iy + 1, iz, it + i);
		float back0 = tech3_noise_lookup(ix, iy, iz + 1, it + i);
		float back1 = tech3_noise_lookup(ix + 1, iy, iz + 1, it + i);
		float back2 = tech3_noise_lookup(ix, iy + 1, iz + 1, it + i);
		float back3 = tech3_noise_lookup(ix + 1, iy + 1, iz + 1, it + i);
		float fvalue = mix(mix(front0, front1, fx), mix(front2, front3, fx), fy);
		float bvalue = mix(mix(back0, back1, fx), mix(back2, back3, fx), fy);
		value[i] = mix(fvalue, bvalue, fz);
	}
	return mix(value[0], value[1], ft);
}

#endif // NOISE_LOOKUP

#ifdef TECH3_WAVE
float tech3_wave(int wave_fn, float t, float base, float amp, float phase, float freq) {
	float w = 0.0;
	if (wave_fn == 5) {
#ifdef NOISE_LOOKUP
		w = tech3_noise_get4f(0.0, 0.0, 0.0, (t + phase) * freq);
#else
		w = sin((phase + t * freq) * 6.28318530718);
#endif
	} else {
		float x = phase + t * freq;
		if (wave_fn == 0) { w = sin(x * 6.28318530718); }
		else if (wave_fn == 1) { w = sign(sin(x * 6.28318530718)); }
		else if (wave_fn == 2) { w = 1.0 - abs(2.0 * fract(x) - 1.0); }
		else if (wave_fn == 3) { w = fract(x); }
		else if (wave_fn == 4) { w = 1.0 - fract(x); }
		else { w = sin(x * 6.28318530718); }
	}
	return base + w * amp;
}
#endif // TECH3_WAVE


#if OFFSET_MAPPING
// DP-style linear offset: 2 samples, step = scale/2.
// textureGrad keeps the mip from the unshifted UV. An implicit sample
// takes derivatives of the already-shifted coord, which explodes next to
// the surface and is the close-up swim. White flush: height 1 is the
// surface. bias lowers that flush point.
vec2 tech3_offset(sampler2D height_tex, vec2 uv, vec3 eye, float scale, float bias, vec2 ddx, vec2 ddy) {
	vec2 offset_vector = normalize(eye).xy * vec2(-1.0, 1.0) * scale * 0.5;
	vec2 flush_step = (1.0 - bias) * offset_vector;
	vec2 p = uv;
	p += flush_step - textureGrad(height_tex, p, ddx, ddy).r * offset_vector;
	p += flush_step - textureGrad(height_tex, p, ddx, ddy).r * offset_vector;
	return p - uv;
}

#if RELIEF_MAPPING
// DP-style relief: linear search, then binary refine.
// ray.z starts at the flush point and steps toward 0. March while the
// stored height is still below the ray, so a deep texel stops at the
// surface instead of being shoved by the full scale.
vec2 tech3_relief(sampler2D height_tex, vec2 uv, vec3 eye, float scale, float bias) {
	vec3 ray = vec3(normalize(eye).xy * vec2(-1.0, 1.0) * scale, -1.0);
	vec3 rt = vec3(uv, 1.0 - bias);
	ray *= 0.125;
	for (int i = 0; i < 8; i++) {
		rt += ray * step(texture(height_tex, rt.xy).r, rt.z);
	}
	float refine = 1.0;
	for (int i = 0; i < 4; i++) {
		rt += ray * (step(texture(height_tex, rt.xy).r, rt.z) * refine - 0.5 * refine);
		refine *= 0.5;
	}
	return rt.xy - uv;
}
#endif

vec2 tech3_parallax(sampler2D height_tex, vec2 uv, vec3 eye, float scale, float bias, vec2 ddx, vec2 ddy) {
#if RELIEF_MAPPING
	return tech3_relief(height_tex, uv, eye, scale, bias);
#else
	return tech3_offset(height_tex, uv, eye, scale, bias, ddx, ddy);
#endif
}
#endif
