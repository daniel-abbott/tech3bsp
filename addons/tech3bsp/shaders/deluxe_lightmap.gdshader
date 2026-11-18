shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert;

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

uniform sampler2D albedo_texture : source_color, hint_default_white, TEXTURE_FILTER, repeat_enable;
uniform sampler2D lightmap_texture : hint_default_white, filter_linear, repeat_disable;
uniform sampler2D deluxemap_texture : hint_default_white, filter_linear, repeat_disable;
uniform sampler2D normal_texture : hint_normal, TEXTURE_FILTER, repeat_enable;
uniform sampler2D gloss_texture : hint_default_black, TEXTURE_FILTER, repeat_enable;
uniform sampler2D glow_texture : hint_default_black, TEXTURE_FILTER, repeat_enable;
uniform samplerCube reflect_cube : source_color, filter_linear_mipmap;
uniform sampler2D reflect_mask : hint_default_white, TEXTURE_FILTER, repeat_enable;
uniform float tech3_deluxe = 0.0;
uniform float tech3_has_normal = 0.0;
uniform float tech3_has_height = 0.0;
uniform float tech3_has_gloss = 0.0;
uniform float tech3_has_glow = 0.0;
uniform float tech3_has_reflect = 0.0;
uniform float tech3_has_cube = 0.0;
uniform float tech3_offset_scale = 0.02;
uniform float tech3_offset_bias = 0.0;
uniform sampler2D offset_texture : hint_default_white, TEXTURE_FILTER, repeat_enable;
uniform float tech3_has_offset = 0.0;
uniform vec4 albedo_color : source_color = vec4(1.0);
global uniform sampler2D tech3_style_weights : hint_default_white, filter_nearest, repeat_disable;

varying vec4 lm_uv_a;
varying vec4 lm_uv_b;
varying vec4 lm_styles;
varying vec4 lm_cell;
varying vec4 vert_color;
varying vec3 v_geom_n;
varying vec3 v_tangent;
varying vec3 v_binormal;

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
	v_geom_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_tangent = normalize((MODEL_MATRIX * vec4(TANGENT, 0.0)).xyz);
	v_binormal = normalize((MODEL_MATRIX * vec4(BINORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 t3_uv = UV;
	if (tech3_has_height > 0.5 && length(TANGENT) > 0.5) {
		vec2 texel = 1.0 / vec2(textureSize(normal_texture, 0));
		float h = texture(normal_texture, UV).r;
		float hx = texture(normal_texture, UV + vec2(texel.x, 0.0)).r;
		float hy = texture(normal_texture, UV + vec2(0.0, texel.y)).r;
		vec3 tn = normalize(vec3((h - hx) * 4.0, (h - hy) * 4.0, 1.0));
		NORMAL = normalize(TANGENT * tn.x + BINORMAL * tn.y + NORMAL * tn.z);
		vec3 eye = normalize(vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL)));
		#if OFFSET_MAPPING
		t3_uv += eye.xy * vec2(-1.0, 1.0) * 0.004 * (0.5 - h);
#endif
	}
#if OFFSET_MAPPING
	if (tech3_has_offset > 0.5 && tech3_offset_scale > 0.0001 && length(TANGENT) > 0.5) {
		vec3 eye_n = vec3(dot(VIEW, TANGENT), dot(VIEW, BINORMAL), dot(VIEW, NORMAL));
		t3_uv += tech3_parallax(offset_texture, t3_uv, eye_n, tech3_offset_scale, tech3_offset_bias, dFdx(UV), dFdy(UV));
	}
#endif
	if (tech3_has_normal > 0.5 && length(TANGENT) > 0.5) {
		vec3 tn = texture(normal_texture, t3_uv).rgb * 2.0 - 1.0;
		tn.z = sqrt(max(1.0 - dot(tn.xy, tn.xy), 0.0));
		NORMAL = normalize(TANGENT * tn.x + BINORMAL * tn.y + NORMAL * tn.z);
	}
	ALBEDO = texture(albedo_texture, t3_uv).rgb * albedo_color.rgb;
	if (tech3_has_glow > 0.5) {
		EMISSION += texture(glow_texture, t3_uv).rgb;
	}
	if (tech3_has_cube > 0.5 && tech3_has_reflect > 0.5) {
		vec3 cube_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 cube_v = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
		vec3 cube_r = reflect(-cube_v, cube_n);
		cube_r = vec3(-cube_r.x, cube_r.z, cube_r.y);
		float cube_m = texture(reflect_mask, t3_uv).r;
		ALBEDO += texture(reflect_cube, cube_r).rgb * clamp(cube_m, 0.0, 1.0);
	}
	float t3_gloss = 1.0;
	if (tech3_has_gloss > 0.5) {
		t3_gloss = texture(gloss_texture, t3_uv).r;
	}
	SPECULAR = clamp(t3_gloss, 0.0, 1.0);
	ROUGHNESS = clamp(1.0 - SPECULAR, 0.04, 1.0);
}

void light() {
	vec3 geom_l = normalize((VIEW_MATRIX * vec4(v_geom_n, 0.0)).xyz);
	bool tech3_lm_pass = LIGHT_IS_DIRECTIONAL && LIGHT_COLOR == vec3(0.0);
	if (tech3_lm_pass) {
		vec2 uv_lm0 = lm_cell.xy + UV2 * lm_cell.zw;
		vec3 lm_sum = texture(lightmap_texture, uv_lm0).rgb * tech3_style_rgb(lm_styles.r * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_a.xy).rgb * tech3_style_rgb(lm_styles.g * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_a.zw).rgb * tech3_style_rgb(lm_styles.b * 255.0);
		lm_sum += texture(lightmap_texture, lm_uv_b.xy).rgb * tech3_style_rgb(lm_styles.a * 255.0);

		vec3 l_w = normalize(texture(deluxemap_texture, uv_lm0).rgb * 2.0 - 1.0);
		vec3 n_w = normalize(v_geom_n);
		vec3 t_w = v_tangent;
		vec3 b_w = v_binormal;
		vec3 l_ts = normalize(vec3(dot(l_w, t_w), dot(l_w, b_w), dot(l_w, n_w)));
		vec3 lm_base = lm_sum * (1.0 / max(0.25, l_ts.z));
		vec3 l_view = normalize((VIEW_MATRIX * vec4(l_w, 0.0)).xyz);
		float ndotl = max(dot(normalize(NORMAL), l_view), 0.0);
		lm_sum = clamp(lm_base * max(ndotl, 0.35), 0.0, 4.0);
		if (tech3_has_gloss > 0.5) {
			vec2 gloss_uv = UV;
			vec3 gt = normalize((VIEW_MATRIX * vec4(v_tangent, 0.0)).xyz);
			vec3 gb = normalize((VIEW_MATRIX * vec4(v_binormal, 0.0)).xyz);
			vec3 ge = normalize(vec3(dot(VIEW, gt), dot(VIEW, gb), dot(VIEW, NORMAL)));
			if (tech3_has_height > 0.5 && dot(v_tangent, v_tangent) > 0.25) {
				float gh = texture(normal_texture, UV).r;
				#if OFFSET_MAPPING
				gloss_uv += ge.xy * vec2(-1.0, 1.0) * 0.004 * (0.5 - gh);
#endif
			} else if (tech3_has_offset > 0.5 && tech3_offset_scale > 0.0001 && dot(v_tangent, v_tangent) > 0.25) {
#if OFFSET_MAPPING
				gloss_uv += tech3_parallax(offset_texture, gloss_uv, ge, tech3_offset_scale, tech3_offset_bias, dFdx(UV), dFdy(UV));
#endif
			}
			float gloss = texture(gloss_texture, gloss_uv).r;
			vec3 spec_h = normalize(l_view + VIEW);
			float spec = pow(max(dot(normalize(NORMAL), spec_h), 0.0), 16.0);
			SPECULAR_LIGHT += spec * gloss * lm_sum * ATTENUATION;
		}
		if (lm_cell.z + lm_cell.w < 0.000001) {
			DIFFUSE_LIGHT = vert_color.rgb * tech3_style_rgb(lm_styles.r * 255.0) * ATTENUATION;
		} else {
			DIFFUSE_LIGHT = lm_sum * ATTENUATION;
		}
	} else if (dot(geom_l, LIGHT) > 0.0) {
		DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;
		if (tech3_has_gloss > 0.5) {
			vec2 gloss_uv = UV;
			vec3 gt = normalize((VIEW_MATRIX * vec4(v_tangent, 0.0)).xyz);
			vec3 gb = normalize((VIEW_MATRIX * vec4(v_binormal, 0.0)).xyz);
			vec3 ge = normalize(vec3(dot(VIEW, gt), dot(VIEW, gb), dot(VIEW, NORMAL)));
			if (tech3_has_height > 0.5 && dot(v_tangent, v_tangent) > 0.25) {
				float gh = texture(normal_texture, UV).r;
				#if OFFSET_MAPPING
				gloss_uv += ge.xy * vec2(-1.0, 1.0) * 0.004 * (0.5 - gh);
#endif
			} else if (tech3_has_offset > 0.5 && tech3_offset_scale > 0.0001 && dot(v_tangent, v_tangent) > 0.25) {
#if OFFSET_MAPPING
				gloss_uv += tech3_parallax(offset_texture, gloss_uv, ge, tech3_offset_scale, tech3_offset_bias, dFdx(UV), dFdy(UV));
#endif
			}
			float gloss = texture(gloss_texture, gloss_uv).r;
			vec3 h = normalize(LIGHT + VIEW);
			SPECULAR_LIGHT += pow(max(dot(NORMAL, h), 0.0), 32.0) * gloss * ATTENUATION * LIGHT_COLOR;
		}
	}
}
