shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

uniform sampler2D albedo_texture : source_color, hint_default_white, TEXTURE_FILTER, repeat_enable;
uniform sampler2D lightmap_texture : hint_default_white, filter_linear, repeat_disable;
uniform vec4 albedo_color : source_color = vec4(1.0);
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
	ALBEDO = texture(albedo_texture, UV).rgb * albedo_color.rgb;
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
