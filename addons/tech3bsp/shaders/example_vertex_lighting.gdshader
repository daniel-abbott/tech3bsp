shader_type spatial;
render_mode blend_mix, vertex_lighting, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;//, ambient_light_disabled;//, unshaded;

// q3map2 will bake vertex colors as well as lightmaps
// set up your map compilation shaders to subdivide everything,
// then use a shader that acknowledges vertex colors. Instant PS1 graphics!

uniform sampler2D albedo_texture : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_enable;
// source_color here can crush out the colors for RGB8 lightmaps
//uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

// sRGB compensation, not currently in use
//void vertex() {
	//COLOR = vec4(pow(COLOR.rgb, vec3(2.2)), 1.0);
//}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb * COLOR.rgb;
}
