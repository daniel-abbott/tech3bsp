shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

#include "res://addons/tech3bsp/shaders/options.gdshaderinc"

uniform sampler2D albedo_texture : source_color, hint_default_white, TEXTURE_FILTER, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);

varying vec4 vert_color;

void vertex() {
	vert_color = COLOR; // can't access COLOR from light()
}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = albedo.rgb;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT = vert_color.rgb * ATTENUATION;
	} else {
		DIFFUSE_LIGHT += max(dot(NORMAL, LIGHT), 0.0) * ATTENUATION * LIGHT_COLOR;
	}
}
