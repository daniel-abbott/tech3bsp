shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, specular_disabled, fog_disabled;

#define TECH3_TIME

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float alpha_test : hint_range(0.0, 1.0) = 0.75;
uniform int billboard_y = 0;
uniform float fade_start = 0.0;
uniform float fade_end = 0.0;
uniform float fx_duration = 0.0;
uniform vec2 fx_grow = vec2(0.0);
uniform vec2 fx_alpha = vec2(1.0, 1.0);
uniform int fx_fadeinout = 0;
uniform float ss_wind = 0.0;
uniform vec3 ss_wind_dir = vec3(1.0, 0.0, 0.0);
// Runtime scale and direction from BSPScene.set_ss_wind. Scale defaults to 1.
global uniform float tech3_ss_wind_scale;
global uniform vec3 tech3_ss_wind_dir;
varying float ss_fade;
varying float ss_fx_a;

void vertex() {
	float pos = 0.0;
	if (fx_duration > 0.001) {
		pos = fract(tech3_time / fx_duration + INSTANCE_CUSTOM.r);
		VERTEX.x *= 1.0 + pos * fx_grow.x;
		VERTEX.y *= 1.0 + pos * fx_grow.y;
	}
	if (fx_duration > 0.001) {
		float span = fx_alpha.y - fx_alpha.x;
		if (fx_fadeinout != 0) {
			if (pos > 0.5) {
				ss_fx_a = fx_alpha.x + span * (pos - 0.5) * 2.0;
			} else {
				ss_fx_a = fx_alpha.x + span * (0.5 - pos) * 2.0;
			}
		} else {
			ss_fx_a = fx_alpha.x + span * pos;
		}
	} else {
		ss_fx_a = 1.0;
	}
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 scale = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	vec3 world;
	if (billboard_y != 0) {
		vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
		vec3 up = vec3(0.0, 1.0, 0.0);
		if (billboard_y == 2) {
			up = normalize(INV_VIEW_MATRIX[1].xyz);
		}
		world = origin + right * VERTEX.x * scale.x + up * VERTEX.y * scale.y;
	} else {
		world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
	float wind = ss_wind * tech3_ss_wind_scale;
	vec3 wdir = ss_wind_dir;
	if (length(tech3_ss_wind_dir) > 0.01) {
		wdir = normalize(tech3_ss_wind_dir);
	}
	if (wind > 0.001) {
		float ang = (origin.x + origin.z) * 0.02 + tech3_time * 1.5;
		float h = VERTEX.y * scale.y;
		float sway = h * wind * 0.075;
		world += vec3(cos(ang), 0.0, sin(ang)) * sway;
		world += normalize(wdir + vec3(0.0001, 0.0, 0.0)) * (h * wind);
		world.y += sin(ang * 2.5) * sway * 0.4;
		if (fx_duration > 0.001) {
			world += normalize(wdir + vec3(0.0001, 0.0, 0.0)) * (pos * wind * 0.25);
		}
	}
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
	ss_fade = 1.0;
	if (fade_end > fade_start && fade_end > 0.0) {
		float dist = length(INV_VIEW_MATRIX[3].xyz - origin);
		ss_fade = 1.0 - smoothstep(fade_start, fade_end, dist);
	}
}

void fragment() {
	float a = max(ss_fade * ss_fx_a, 0.0);
	vec4 c = texture(albedo_tex, UV);
	ALBEDO = c.rgb * COLOR.rgb * a;
}
