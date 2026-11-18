shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

// Per-cell style modulation variant of entity.gdshader.
// Samples the 8 neighboring lightgrid cells with nearest, applies each cell's
// own style weights to its ambient/direct, then trilinear-interpolates the
// weighted results. Fixes style bleed where a linear filter mixes colors from
// cells with different styles before the (single) style weight is applied.
// Cartesian (light direction) stays a single linear sample (it is not styled).
// More expensive than the simple entity (8x color/style fetches).

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

// Weighted ambient + direct for one grid cell (style applied before blend).
// Cartesian is style-independent and stays a single linear sample.
void sample_cell(ivec3 cell, out vec3 amb, out vec3 dir) {
	vec4 st = texelFetch(light_grid_styles, cell, 0);
	vec3 w0 = tech3_style_rgb(st.r * 255.0);
	vec3 w1 = tech3_style_rgb(st.g * 255.0);
	vec3 w2 = tech3_style_rgb(st.b * 255.0);
	vec3 w3 = tech3_style_rgb(st.a * 255.0);
	amb = texelFetch(light_grid_ambient, cell, 0).rgb * w0;
	amb += texelFetch(light_grid_ambient_1, cell, 0).rgb * w1;
	amb += texelFetch(light_grid_ambient_2, cell, 0).rgb * w2;
	amb += texelFetch(light_grid_ambient_3, cell, 0).rgb * w3;
	dir = texelFetch(light_grid_direct, cell, 0).rgb * w0;
	dir += texelFetch(light_grid_direct_1, cell, 0).rgb * w1;
	dir += texelFetch(light_grid_direct_2, cell, 0).rgb * w2;
	dir += texelFetch(light_grid_direct_3, cell, 0).rgb * w3;
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
		ivec3 grid_size = textureSize(light_grid_ambient, 0);
		vec3 tex_coord = world_position * vec3(grid_size);
		vec3 base_f = tex_coord - 0.5;
		ivec3 base = ivec3(floor(base_f));
		vec3 frac = clamp(base_f - vec3(base), vec3(0.0), vec3(1.0));

		vec3 amb = vec3(0.0);
		vec3 dir = vec3(0.0);
		for (int dz = 0; dz < 2; dz++) {
			for (int dy = 0; dy < 2; dy++) {
				for (int dx = 0; dx < 2; dx++) {
					ivec3 cell = base + ivec3(dx, dy, dz);
					cell = clamp(cell, ivec3(0), grid_size - ivec3(1));
					float wx = dx == 0 ? (1.0 - frac.x) : frac.x;
					float wy = dy == 0 ? (1.0 - frac.y) : frac.y;
					float wz = dz == 0 ? (1.0 - frac.z) : frac.z;
					float w = wx * wy * wz;
					vec3 c_amb, c_dir;
					sample_cell(cell, c_amb, c_dir);
					amb += c_amb * w;
					dir += c_dir * w;
				}
			}
		}
		vec3 cart = texture(light_grid_cartesian, world_position).xyz;
		vec3 light_dir = cart * 2.0 - 1.0;
		vec3 normal = normalize(world_normal);
		float NdotL = max(dot(normal, light_dir), 0.0);
		DIFFUSE_LIGHT = (amb + dir * NdotL) * ATTENUATION;
	} else {
		DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;
	}
}
