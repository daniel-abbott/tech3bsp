shader_type spatial;
render_mode blend_mul, depth_draw_always, cull_back, unshaded;

// we can put the lightmap textures on a second material pass
// however this has a huge performance impact verses just mixing within
// a single shader.
uniform sampler2D lightmap_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;

void fragment() {
	EMISSION = texture(lightmap_texture, UV2).rgb;
}
