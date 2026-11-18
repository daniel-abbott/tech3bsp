@tool
class_name Tech3Noise
extends RefCounted
# Shared noise and wave form.
# TABLE / PERM are the source of truth. The GPU path samples a 256x1 RG
# ImageTexture built from these arrays (R = table, G = perm as float).

const WAVE_SIN := 0
const WAVE_SQUARE := 1
const WAVE_TRIANGLE := 2
const WAVE_SAWTOOTH := 3
const WAVE_INVERSESAWTOOTH := 4
const WAVE_NOISE := 5


static var TABLE: PackedFloat32Array = PackedFloat32Array([
	-0.243600743, -0.708311174, 0.614138956, -0.465880982, -0.373075658, 0.600993682, 0.566212135, 0.779936225,
	0.272596626, 0.297702741, -0.437207898, -0.571663685, 0.460834018, 0.644290064, -0.059001086, 0.498018936,
	-0.630056904, -0.078459743, -0.164439952, 0.631463029, 0.550056613, 0.326985974, 0.514747905, 0.368364335,
	0.634070991, 0.623345417, 0.466317306, -0.830927111, 0.798583827, -0.463040169, 0.233442994, -0.811969474,
	0.974831386, -0.093768987, 0.000657136, -0.202791623, 0.809626109, -0.419941198, -0.070213181, 0.859544367,
	-0.623705895, -0.933721412, -0.754108449, 0.752380722, -0.364387342, -0.069901194, 0.073200765, -0.859098539,
	-0.353252278, -0.057461563, 0.021051312, 0.501569905, 0.528191424, 0.978864511, -0.480175031, 0.395566166,
	-0.831300439, -0.332970399, -0.093114068, 0.492224657, -0.311770895, 0.786109333, 0.262518319, 0.342471585,
	-0.351124303, -0.585260127, 0.995863671, -0.097737543, -0.984188849, -0.170444559, 0.180858451, 0.806019575,
	-0.131779046, -0.846374202, 0.642171542, 0.390069538, 0.860241762, -0.245106246, -0.208858249, 0.466080741,
	0.431898906, 0.394612667, 0.211715306, 0.844500878, 0.770043886, 0.125783939, 0.996383357, -0.392005562,
	0.519291877, 0.941594523, -0.167880525, 0.134880208, 0.242959222, -0.826145586, -0.163682846, 0.872568772,
	0.634000941, -0.358565841, -0.857272690, -0.138999991, -0.524051780, 0.548702349, -0.762604220, 0.006080598,
	-0.646154078, -0.866036881, 0.044600824, -0.896878488, 0.115190080, 0.067893658, -0.237209377, 0.610275523,
	0.080865397, 0.601981696, -0.549479222, -0.828025304, 0.006082749, 0.466963012, 0.362391817, 0.892367900,
	-0.208683313, 0.521258932, 0.034986685, 0.358758294, -0.056757072, 0.149413828, -0.877191750, 0.415040836,
	-0.214324133, -0.589467380, 0.984216805, 0.685139784, 0.420506066, -0.063281726, 0.017367559, 0.846446187,
	0.438637762, 0.581509304, 0.746148149, 0.653255396, 0.380926362, -0.181682732, -0.343883870, 0.710204557,
	-0.050884055, 0.888864276, -0.219563519, -0.004289887, -0.033223236, -0.298379521, 0.035819101, 0.135405303,
	-0.909757258, -0.519758422, -0.691543689, 0.425577664, -0.730451027, 0.162006323, -0.710039643, -0.393393472,
	-0.040630774, 0.546254006, 0.063300903, 0.386400529, -0.920046562, -0.807178032, 0.438742536, 0.713835091,
	0.728065221, 0.070483100, -0.960217735, -0.197810061, -0.362080643, 0.955383335, 0.139087024, 0.902586595,
	0.392119302, 0.579479155, 0.244431163, 0.827425876, -0.617405319, 0.528975089, -0.565366043, 0.223825396,
	-0.478461208, -0.107238788, -0.554502895, 0.597057068, -0.297653893, 0.660850649, 0.505742225, 0.083984599,
	-0.989450233, -0.127182934, 0.922948356, -0.023499004, -0.315240914, 0.516232182, -0.580510540, -0.005033940,
	0.827597051, -0.824896742, 0.218471924, 0.311643892, 0.866637818, 0.428310607, 0.879672053, 0.324140385,
	0.765344216, -0.001954916, 0.885473574, 0.178840735, -0.015994751, 0.648245592, 0.976805138, -0.955653071,
	-0.809326412, 0.833036584, -0.760922184, 0.134915256, -0.277896920, 0.095165555, -0.061877397, 0.483893797,
	-0.205313759, -0.785559449, -0.893872088, -0.532840065, -0.534608239, -0.893832337, 0.877577084, 0.076557845,
	0.342702000, 0.469588530, 0.575185875, 0.943336003, 0.047550491, 0.186317836, 0.545839968, -0.888415322,
	-0.575740563, 0.468780813, 0.746532465, -0.438326560, 0.501477218, 0.758650740, 0.080301391, -0.516311347,
	-0.796884121, 0.375286442, 0.482167194, -0.699129023, 0.809288642, -0.085830207, -0.244929758, 0.443052874
])


static var PERM: PackedInt32Array = PackedInt32Array([
	194, 27, 85, 47, 45, 115, 159, 71, 139, 4, 23, 182, 25, 39, 104, 54,
	194, 3, 137, 203, 11, 7, 136, 178, 197, 63, 57, 37, 185, 140, 195, 1,
	31, 184, 22, 77, 250, 116, 47, 165, 100, 38, 83, 123, 157, 167, 21, 66,
	24, 214, 72, 117, 77, 18, 208, 124, 132, 142, 80, 116, 111, 139, 180, 213,
	164, 108, 168, 251, 6, 175, 226, 143, 250, 196, 83, 196, 143, 196, 51, 139,
	118, 5, 244, 145, 227, 148, 17, 43, 81, 143, 181, 25, 25, 85, 89, 48,
	243, 161, 36, 222, 93, 128, 64, 152, 205, 44, 13, 22, 220, 185, 41, 132,
	61, 186, 101, 131, 158, 170, 142, 19, 107, 79, 35, 88, 102, 229, 219, 68,
	43, 66, 32, 24, 143, 194, 80, 211, 221, 38, 249, 116, 245, 67, 224, 33,
	77, 162, 241, 46, 205, 239, 19, 8, 145, 87, 204, 245, 134, 183, 225, 196,
	234, 187, 179, 76, 173, 209, 154, 213, 169, 254, 16, 97, 201, 156, 190, 211,
	5, 231, 114, 244, 62, 127, 228, 91, 3, 180, 109, 52, 42, 198, 146, 230,
	83, 248, 118, 158, 70, 136, 38, 176, 49, 131, 199, 225, 200, 128, 172, 145,
	68, 55, 62, 187, 66, 243, 203, 226, 128, 241, 58, 215, 127, 142, 151, 93,
	2, 101, 128, 178, 104, 66, 122, 248, 243, 252, 24, 120, 224, 43, 18, 204,
	106, 187, 44, 228, 167, 106, 15, 240, 72, 27, 235, 35, 55, 10, 22, 90
])


const TEX_WIDTH := 256

static var _texture: ImageTexture = null


## 256×1 RG ImageTexture of TABLE (R) and PERM (G). Built once.
## Usage: RenderingServer.global_shader_parameter_set(&"tech3_noise", Tech3Noise.noise_texture())
static func noise_texture() -> ImageTexture:
	if _texture != null:
		return _texture
	var img := Image.create(TEX_WIDTH, 1, false, Image.FORMAT_RGF)
	for i in TEX_WIDTH:
		# R = signed table value. G = perm index as an exact f32 integer.
		img.set_pixel(i, 0, Color(TABLE[i], float(PERM[i]), 0.0, 1.0))
	_texture = ImageTexture.create_from_image(img)
	return _texture


## Bind the noise texture to the tech3_noise shader global if the project defines it.
## Usage: Tech3Noise.ensure_shader_global()
static func ensure_shader_global() -> void:
	if not ProjectSettings.has_setting("shader_globals/tech3_noise"):
		return
	RenderingServer.global_shader_parameter_set(&"tech3_noise", noise_texture())


static func _val(a: int) -> int:
	return PERM[a & 255]


static func _lookup(x: int, y: int, z: int, t: int) -> float:
	# INDEX(x,y,z,t) = VAL(x + VAL(y + VAL(z + VAL(t))))
	return TABLE[_val(x + _val(y + _val(z + _val(t))))]


## 4D value noise, linear lerp, no fade. Same lattice as the GPU helper.
## Usage: var n := Tech3Noise.get4f(0.0, 0.0, 0.0, t)
static func get4f(x: float, y: float, z: float, t: float) -> float:
	var ix := int(floorf(x))
	var fx := x - float(ix)
	var iy := int(floorf(y))
	var fy := y - float(iy)
	var iz := int(floorf(z))
	var fz := z - float(iz)
	var it := int(floorf(t))
	var ft := t - float(it)
	var v0 := 0.0
	var v1 := 0.0
	for i in 2:
		var front0 := _lookup(ix, iy, iz, it + i)
		var front1 := _lookup(ix + 1, iy, iz, it + i)
		var front2 := _lookup(ix, iy + 1, iz, it + i)
		var front3 := _lookup(ix + 1, iy + 1, iz, it + i)
		var back0 := _lookup(ix, iy, iz + 1, it + i)
		var back1 := _lookup(ix + 1, iy, iz + 1, it + i)
		var back2 := _lookup(ix, iy + 1, iz + 1, it + i)
		var back3 := _lookup(ix + 1, iy + 1, iz + 1, it + i)
		var fvalue := lerpf(lerpf(front0, front1, fx), lerpf(front2, front3, fx), fy)
		var bvalue := lerpf(lerpf(back0, back1, fx), lerpf(back2, back3, fx), fy)
		if i == 0:
			v0 = lerpf(fvalue, bvalue, fz)
		else:
			v1 = lerpf(fvalue, bvalue, fz)
	return lerpf(v0, v1, ft)


# Same curves options.gdshaderinc::tech3_wave emits.
## Evaluate a Q3 wave form (sin/square/triangle/saw/invsaw/noise).
## Usage: Tech3Noise.wave(Tech3Noise.WAVE_SIN, time, base, amp, phase, freq)
static func wave(wave_fn: int, t: float, base: float, amp: float, phase: float, freq: float) -> float:
	var w := 0.0
	if wave_fn == WAVE_NOISE:
		w = get4f(0.0, 0.0, 0.0, (t + phase) * freq)
	else:
		var x := phase + t * freq
		match wave_fn:
			WAVE_SIN:
				w = sin(x * TAU)
			WAVE_SQUARE:
				w = signf(sin(x * TAU))
			WAVE_TRIANGLE:
				w = 1.0 - absf(2.0 * (x - floorf(x)) - 1.0)
			WAVE_SAWTOOTH:
				w = x - floorf(x)
			WAVE_INVERSESAWTOOTH:
				w = 1.0 - (x - floorf(x))
			_:
				w = sin(x * TAU)
	return base + w * amp
