shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert;

#define TECH3_TIME
#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

uniform sampler2D t3_fb : hint_screen_texture, filter_linear, repeat_disable;
uniform sampler2D albedo_texture : source_color, hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float tech3_has_normal = 0.0;
uniform sampler2D lightmap_texture : hint_default_white, filter_linear, repeat_disable;
uniform samplerCube reflect_cube : source_color, filter_linear;
uniform float tech3_has_cube = 0.0;
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_scroll = vec2(0.0);
uniform float water_refract_distort = 1.0;
uniform vec3 water_refract_rgb = vec3(1.0);
uniform float water_tint = 0.12;

global uniform sampler2D tech3_style_weights : hint_default_white, filter_nearest, repeat_disable;

varying vec4 lm_uv_a;
varying vec4 lm_uv_b;
varying vec4 lm_styles;
varying vec4 lm_cell;
varying vec4 vert_color;

vec3 tech3_style_rgb(float s255) {
	if (s255 > 254.5) {
		return vec3(0.0);
	}
	if (s255 < 0.5) {
		return vec3(1.0);
	}
	return texture(tech3_style_weights, vec2((s255 + 0.5) / 64.0, 0.5)).rgb;
}

void vertex() {
	lm_uv_a = CUSTOM1;
	lm_uv_b = CUSTOM2;
	lm_styles = CUSTOM3;
	lm_cell = CUSTOM0;
	vert_color = COLOR;
}

void fragment() {
	vec2 t3_uv = UV * uv_scale + uv_scroll * tech3_time;
	// Subtle procedural ripples, cheesy but cheap
	float ripple_t = tech3_time * 0.4;
	vec2 ripple = vec2(
		sin(t3_uv.x * 12.0 + ripple_t) * 0.015 + sin(t3_uv.y * 8.0 - ripple_t * 1.3) * 0.01,
		cos(t3_uv.y * 10.0 + ripple_t * 0.7) * 0.012 + sin(t3_uv.x * 9.0 + ripple_t * 1.1) * 0.008
	);
	vec4 base = texture(albedo_texture, t3_uv + ripple * 0.5);
	vec2 water_n = ripple;
	vec3 tn = vec3(0.0, 0.0, 1.0);
	if (tech3_has_normal > 0.5) {
		tn = texture(normal_texture, t3_uv).rgb * 2.0 - 1.0;
		tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));
		water_n += tn.xy;
		if (length(TANGENT) > 0.5) {
			vec3 ripple_n = normalize(vec3(ripple * 4.0, 1.0));
			NORMAL = normalize(TANGENT * (tn.x + ripple_n.x) + BINORMAL * (tn.y + ripple_n.y) + NORMAL * tn.z);
		}
	} else if (length(TANGENT) > 0.5) {
		vec3 ripple_n = normalize(vec3(ripple * 6.0, 1.0));
		NORMAL = normalize(TANGENT * ripple_n.x + BINORMAL * ripple_n.y + NORMAL * ripple_n.z);
	}
	vec2 refr_uv = clamp(SCREEN_UV + water_n * water_refract_distort * 0.08, vec2(0.001), vec2(0.999));
	vec3 refr = textureLod(t3_fb, refr_uv, 0.0).rgb * water_refract_rgb;
	vec3 cube_add = vec3(0.0);
	if (tech3_has_cube > 0.5) {
		vec3 cube_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 cube_v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 cube_r = reflect(-cube_v, cube_n);
		cube_r = vec3(-cube_r.x, cube_r.z, cube_r.y);
		cube_add = texture(reflect_cube, cube_r).rgb;
	}
	// Refracted opposite-side view always visible. Base map (add) and cube sit on top.
	// Vertex alpha scales the base contribution when present.
	vec3 base_rgb = base.rgb * base.a * vert_color.a;
	EMISSION = refr + base_rgb + cube_add;
	ALBEDO = (refr + base_rgb) * water_tint;
	ALPHA = 1.0;
	ROUGHNESS = 0.05;
	METALLIC = 0.0;
	SPECULAR = 0.5;
}

void light() {
	bool tech3_lm_pass = LIGHT_IS_DIRECTIONAL && LIGHT_COLOR == vec3(0.0);
	if (tech3_lm_pass) {
		vec2 uv_lm0 = lm_cell.xy + UV2 * lm_cell.zw;
		vec3 lm_sum = texture(lightmap_texture, uv_lm0).rgb * tech3_style_rgb(lm_styles.r * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_a.xy).rgb * tech3_style_rgb(lm_styles.g * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_a.zw).rgb * tech3_style_rgb(lm_styles.b * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_b.xy).rgb * tech3_style_rgb(lm_styles.a * 255.0);
		if (lm_cell.z + lm_cell.w < 0.000001) {
			DIFFUSE_LIGHT = vert_color.rgb * tech3_style_rgb(lm_styles.r * 255.0) * ATTENUATION;
		} else {
			DIFFUSE_LIGHT = lm_sum * ATTENUATION;
		}
	} else if (dot(NORMAL, LIGHT) > 0.0) {
		DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;
	}
}
