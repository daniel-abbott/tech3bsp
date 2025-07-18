shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap_anisotropic;
// TODO: should these be source_color also?
global uniform sampler3D light_grid_ambient : filter_linear;
global uniform sampler3D light_grid_direct : filter_linear;
global uniform sampler3D light_grid_cartesian : filter_linear;
global uniform vec3 light_grid_offset;
global uniform vec3 light_grid_normalize;

varying vec3 world_position;
varying vec3 world_normal;

vec3 get_3D_texture_coordinates(vec3 position) {
	position -= light_grid_offset;
	vec3 pos = vec3(position.x / -light_grid_normalize.x, position.z / light_grid_normalize.y, position.y / light_grid_normalize.z);
	return pos;
}

void vertex() {
	world_position = get_3D_texture_coordinates((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	world_normal = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	// if you'd rather use the EMISSION channel, set it up here.
	//vec4 amb = texture(light_grid_ambient, world_position);
	//vec4 dir = texture(light_grid_directional, world_position);
//
	//vec3 light_dir = spherical_to_directional(amb.a, dir.a);

	//vec3 normal = normalize(world_normal);
	//float NdotL = max(dot(normal, light_dir), 0.0);

	//vec3 ambient = amb.rgb;
	//vec3 directional = dir.rgb * NdotL;
	vec4 albedo = texture(albedo_texture, UV);
	ALBEDO = albedo.rgb;// * COLOR.rgb;
	//EMISSION = albedo.rgb * (ambient + directional);// * COLOR.rgb;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		vec3 amb = texture(light_grid_ambient, world_position).rgb;
		vec3 dir = texture(light_grid_direct, world_position).rgb;
		vec3 cart = texture(light_grid_cartesian, world_position).xyz;

		vec3 light_dir = cart * 2.0 - 1.0;

		vec3 normal = normalize(world_normal);
		float NdotL = max(dot(normal, light_dir), 0.0);

		vec3 ambient = amb.rgb;
		vec3 directional = dir.rgb * NdotL;
		DIFFUSE_LIGHT = (ambient + directional);// * ATTENUATION;
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
