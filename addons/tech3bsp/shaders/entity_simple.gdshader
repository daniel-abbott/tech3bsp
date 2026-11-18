shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

// the older, simpler entity shader. Still good when styles are not needed.
// works with styles but can have hard cuts between grids

uniform sampler2D albedo_texture : source_color, TEXTURE_FILTER;
global uniform sampler3D light_grid_ambient : filter_linear, repeat_disable;
global uniform sampler3D light_grid_direct : filter_linear, repeat_disable;
global uniform sampler3D light_grid_cartesian : filter_linear, repeat_disable;
global uniform sampler3D light_grid_ambient_1 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_ambient_2 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_ambient_3 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_direct_1 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_direct_2 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_direct_3 : filter_linear, repeat_disable;
global uniform sampler3D light_grid_styles : filter_nearest, repeat_disable;
global uniform sampler2D tech3_style_weights : hint_default_white, filter_nearest, repeat_disable;
global uniform vec3 light_grid_offset;
global uniform vec3 light_grid_normalize;

varying vec3 world_position;
varying vec3 world_normal;

vec3 tech3_style_rgb(float s255) {
	if (s255 > 254.5) {
		return vec3(0.0);
	}
	if (s255 < 0.5) {
		return vec3(1.0);
	}
	return texture(tech3_style_weights, vec2((s255 + 0.5) / 64.0, 0.5)).rgb;
}

vec3 get_3D_texture_coordinates(vec3 position) {
	vec3 uv = (position - light_grid_offset) / max(light_grid_normalize, vec3(0.0001));
	return clamp(uv, vec3(0.0), vec3(1.0));
}

void vertex() {
	world_position = get_3D_texture_coordinates(MODEL_MATRIX[3].xyz);
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		vec4 st = texture(light_grid_styles, world_position);
		vec3 w0 = tech3_style_rgb(st.r * 255.0);
		vec3 w1 = tech3_style_rgb(st.g * 255.0);
		vec3 w2 = tech3_style_rgb(st.b * 255.0);
		vec3 w3 = tech3_style_rgb(st.a * 255.0);
		vec3 amb = texture(light_grid_ambient, world_position).rgb * w0;
		amb += texture(light_grid_ambient_1, world_position).rgb * w1;
		amb += texture(light_grid_ambient_2, world_position).rgb * w2;
		amb += texture(light_grid_ambient_3, world_position).rgb * w3;
		vec3 dir = texture(light_grid_direct, world_position).rgb * w0;
		dir += texture(light_grid_direct_1, world_position).rgb * w1;
		dir += texture(light_grid_direct_2, world_position).rgb * w2;
		dir += texture(light_grid_direct_3, world_position).rgb * w3;
		vec3 cart = texture(light_grid_cartesian, world_position).xyz;
		vec3 light_dir = cart * 2.0 - 1.0;
		vec3 normal = normalize(world_normal);
		float NdotL = max(dot(normal, light_dir), 0.0);
		DIFFUSE_LIGHT = (amb + dir * NdotL) * ATTENUATION;
	} else {
		DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;
	}
}
