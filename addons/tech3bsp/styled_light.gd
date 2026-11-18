extends Light3D
# Entity adapter for the shared 64-slot style table.
# Same weights drive RBSP face/grid pages and IBSP q3map2 style stages.
# Per-channel Raven overrides (ls_Nr / ls_Ng / ls_Nb) tint the light;
# a scalar pattern scales all three channels together.

@export var style_index: int = 0
@export var base_energy: float = 1.0
@export var base_color: Color = Color.WHITE


func _process(_delta: float) -> void:
	var host := get_parent()
	if host is BSPScene and style_index > 0:
		var c: Color = (host as BSPScene).style_weight_rgb(style_index)
		light_color = Color(base_color.r * c.r, base_color.g * c.g, base_color.b * c.b)
		light_energy = base_energy
	else:
		light_color = base_color
		light_energy = base_energy
