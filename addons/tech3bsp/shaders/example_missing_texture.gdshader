shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;//, ambient_light_disabled;//, unshaded;

// still put lightmaps onto your missing texture fallback, just 'cuz

uniform vec4 albedo_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform sampler2D lightmap_texture : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);

// sRGB compensation, not currently in use
//void vertex() {
	//COLOR = vec4(pow(COLOR.rgb, vec3(2.2)), 1.0);
//}

void fragment() {
	ALBEDO = albedo_color.rgb * COLOR.rgb;
	// putting it on EMISSION also means it should still receive lighting
	// from lights on cullmask 1 without imported lights being a problem
	// bit of a hack though, plus what about when we want ACTUAL emissive textures?
	// also this breaks dark decals, super cool
	//EMISSION = final_texture.rgb * COLOR.rgb;
}

// another hack, we can get entity shadows by having a directional light
// that just lights the entire map
void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 lightmap = texture(lightmap_texture, UV2).rgb;
		DIFFUSE_LIGHT = lightmap * ATTENUATION;
	}
	else
	{
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
		// Here's a Doom 3-ish specular for no real reason.
		// fits in well with Q3 art
		//vec3 half_vec = normalize(VIEW + LIGHT);
		//float spec = pow(max(dot(NORMAL, half_vec), 0.0), 32.0);
		//vec3 specular_color = vec3(1.0) * spec;
		//SPECULAR_LIGHT += specular_color * ALBEDO * LIGHT_COLOR * ATTENUATION;
	}
}