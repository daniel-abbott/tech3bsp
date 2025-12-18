shader_type spatial;
render_mode unshaded, cull_back, depth_draw_always;

// simplified q3-ish sky

uniform sampler2D sky_texture : source_color, filter_linear_mipmap_anisotropic, hint_default_black;
uniform sampler2D cloud_texture : source_color, filter_linear_mipmap_anisotropic, hint_default_black;

uniform float sky_scroll = 0.05;
uniform float cloud_scroll = 0.1;
uniform float sky_arch = 5.0;

void fragment() {
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	dir.y = sky_arch * dir.y;
	dir = normalize(dir);
	vec2 sky_uv = vec2(dir.x, dir.z);
	vec2 cloud_uv = sky_uv;
	sky_uv += TIME * sky_scroll;
	cloud_uv += TIME * cloud_scroll;

	vec3 sky_color = texture(sky_texture, sky_uv).rgb;
	vec3 cloud_color = texture(cloud_texture, cloud_uv).rgb;

	ALBEDO = sky_color + cloud_color;
}
