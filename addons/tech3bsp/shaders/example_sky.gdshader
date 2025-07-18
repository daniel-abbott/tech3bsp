shader_type spatial;
render_mode unshaded, cull_back, depth_draw_always;

// not an actual q3 style sky, just a simple dome

uniform sampler2D sky_texture : source_color, filter_linear, hint_default_black;
uniform sampler2D cloud_texture : source_color, filter_linear, hint_default_black;

uniform float sky_scroll = 0.05;
uniform float cloud_scroll = 0.1;
uniform float vertical_scale = 1.0;
uniform float vertical_offset = 0.0;
uniform float horizon_blend_start = 0.8;
uniform float horizon_blend_end = 1.0;

void fragment() {
	vec3 dir = normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	float u = 0.5 + atan(dir.x, dir.z) / (2.0 * PI);
	float sky_u = u + TIME * sky_scroll;
	float cloud_u = u + TIME * cloud_scroll;
	float v = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
	u = fract(u);
	v = clamp(v * vertical_scale + vertical_offset, 0.0, 1.0);
	vec2 sky_uv = vec2(sky_u, v);
	vec2 cloud_uv = vec2(cloud_u, v);
	cloud_uv.x += TIME * cloud_scroll;
	vec3 sky_color = texture(sky_texture, sky_uv).rgb;
	vec3 cloud_color = texture(cloud_texture, cloud_uv).rgb;
	float fade = smoothstep(horizon_blend_end, horizon_blend_start, v);
	ALBEDO = (sky_color + cloud_color) * fade;
}