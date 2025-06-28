shader_type spatial;
render_mode cull_disabled, blend_add, depth_draw_opaque, depth_prepass_alpha, diffuse_lambert, specular_disabled;

// ultra simple quake-ish liquid shader

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D lightmap_texture : filter_linear_mipmap_anisotropic;
uniform float speed = 1.5;
uniform float wave_strength = 0.05;
uniform float wave_frequency = 4.0;
uniform float emission = 0.0;
uniform vec2 uv_scroll = vec2(0.1, 0.0);
uniform float alpha = 1.0;

// q3map2 can subdivide surfaces, which works well for pointy old-school waves.
void vertex() {
	float wave = sin(VERTEX.x * wave_frequency + TIME * speed)
	           + cos(VERTEX.z * wave_frequency + TIME * speed * 0.8);
	
	VERTEX.y += wave * wave_strength;
}

void fragment() {
	vec2 uv = UV;

	uv.y += sin(uv.x * wave_frequency + TIME * speed) * wave_strength;
	uv.x += cos(uv.y * wave_frequency + TIME * speed * 1.2) * wave_strength;

	uv += TIME * uv_scroll;

	ALBEDO = texture(albedo_texture, uv).rgb;
	ALPHA = alpha;
	EMISSION = ALBEDO * emission; // lava or slime probably
}

// another hack, we can get entity shadows by having a directional light
// that just lights the entire map
void light() {
	vec3 lightmap = texture(lightmap_texture, UV2).rgb;
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT = lightmap * ATTENUATION;
	} else {
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
		// Here's a Doom 3-ish specular for no real reason.
		// fits in well with Q3 art
		//vec3 half_vec = normalize(VIEW + LIGHT);
		//float spec = pow(max(dot(NORMAL, half_vec), 0.0), 32.0);
		//vec3 specular_color = vec3(1.0) * spec;
		//SPECULAR_LIGHT += specular_color * ALBEDO * LIGHT_COLOR * ATTENUATION;
	}
}