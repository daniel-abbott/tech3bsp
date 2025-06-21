# tech3bsp
---
An importer addon for Godot to import an idTech3 BSP file as a Godot scene.

Currently supports "Quake 3 Arena" and Return to "Castle Wolfenstein" BSPs, with potential plans to add Raven BSP (Jedi Outcast, etc.)

If you want to work with Quake 1, Quake 2, Half-Life, or an alternate implementation of Quake 3 Arena BSP's, please check out https://github.com/jitspoe/godot_bsp_importer (which inspired this project).


### Features
- Brush, static mesh, and patch geometry with lightmap and vertex color support.
- Import light volumes (lightgrid) for lighting dynamic objects.
- Imports billboard meshes (typically light flares) - this is still WIP, right now these are just saved as a MultiMesh.
- Material remapping, and fallback automatic texture + lightmap generation.
- Entity remapping via a ConfigFile, automatically adds your own configured scenes into the imported map.
- Includes simple example shaders and scenes for entity mapping.


### Installation and Usage
Place "addons/tech3bsp" into your Godot project (remember to include the "addons" directory itself), and enable it in "Project -> Project Settings -> Plugins". Any BSP files placed into your project directory will be automatically converted to Godot scenes.

You can find very simple examples for shaders which support idTech3 lightmaps and light volumes, as well as an example entity remap ConfigFile and example scenes for BSP entities.

With regards to entity imports, the addon will try and push entity keys (e.g. `angles`, `wait`, etc.) to your scenes, so if you want to actually use those values remember to have an `@export var` with the same name as the entity key (i.e `@export var angles`, `@export var wait`), otherwise the value will just be ignored (the entity remap will still occur).


### Import Options
Unit Scale: 
- Scale the resulting scene map size. The default value results in roughly equivalent scaling to Quake 3 Arena. Defaults to 32.0.

Light Brightness Scale: 
- Scale light brightness for imported lights (does not affect lightmaps or the lightgrid). Defaults to 16.0.

Entity Map: 
- A path to a ConfigFile where entity remaps can be defined. Please check the "examples" directory for an example file.

Print Missing Entities: 
- Whether to print to the console when entity remaps are not present (this can be noisy on entity-heavy BSPs if you don't have remaps set up yet). Enabled by default.

Materials Path: 
- Path for material overrides. The BSP stores textures with a pattern similar to "textures/base/wall01" - the addon will reinterpret this to import Godot materials, so the pattern "res://materials//{texture_name}.material" will load "res://materials/base/wall01.material")

Water, Slime, and Lava Scenes: 
- PackedScene's for BSP liquids, please see the example scenes in the "examples" directory.

Import Lights: 
- If a map is compiled with `-keeplights` the light entities can be imported with this enabled. If lightmaps are also imported, these lights will not affect anything on the same culling layer as the map scene.

Entity Shadow Light: 
- The entire scene is lit via a generated DirectionalLight3D (see special notes below). This toggles whether this light will also cast shadows from meshes other than the map. These meshes will need to be on visibility layers other than 1 to do any shadowcasting. Disabled by default.

Import Billboards: 
- Whether to import lightflares. This is a WIP as its not critical for my own project. Disabled by default.

Import Lightmaps: 
- Whether to import pre-baked lighting data from the BSP. This will be stored in the scene itself, rather than saved as individual images to the "res" directory. Enabled by default.

Import Lightgrid: 
- Whether to import the lightgrid for lighting dynamic meshes. Default enabled.

Split Mesh: 
- Splits the mesh up by surfaces, though at some point this will be reworked to either split along a grid or somehow use vis data from the BSP itself. Godot seems to run best with a small amount of meshes that contain a large amount of geometry, rather than many meshes containing a small amount of geometry, so this is disabled by default.

Occlusion Culling: 
- Generates occlusion geometry, still somewhat WIP. Default disabled.

Remove Skies:
- Allows skipping importing sky geometry, if you want to use Godot skies instead. Disabled by default.
Patch Detail:
- How much tesselated geometry should be generated for patches, higher means more detailed. Default 5 (probably shouldn't go much higher than this).


### Special Notes, Hacks, and Limitations
Right now this whole addon is a bit of a hack, Godot doesn't technically support importing pre-baked lightmaps yet (see proposal https://github.com/godotengine/godot-proposals/issues/11116).
- At the moment the lightmap image data cannot be assigned to StandardMaterial3D, only ShaderMaterial types. The addon expects there to be a `lightmap_texture` uniform when importing lightmaps (this should work with VisualShaders as well).
- Since Godot doesn't support pre-baked lightmaps yet, there are basically three shader options for actually using idTech3 lightmaps: 
    - Use `render_mode unshaded` - functional, however no dynamic lighting can be used (no muzzle flashes or glowing plasma balls).
    - Use the `EMISSION` channel - allows dynamic lights, however dark decals will be invisible.
    - Use a custom `light()` stage and ignore light direction when `LIGHT_IS_DIRECTIONAL`. This is the method currently used in the example shaders, as this will work with decals and dynamic lights, as well as allow simple mesh directional shadows (if desired).
- The lightgrid Texture3D's for ambient and directional pre-baked entity lighting is currently stored in the resulting scenes metadata, and can be accessed via the `get_meta()` function. An example entity shader using this data can be found in the "shaders" directory.
- Since Godot doesn't make it easy to intersect visual geometry with any sort of raycasts, idTech3 "flags" and "content_flags" data is stored into collision metadata as a Dictionary called `planes`, where the key is the normal (Vector3) of the collision plane. This can be accessed via RayCasts and other physics collisions by using `is_equal_approx` (e.g. `for k in planes.keys(): if RayCast3D.get_collision_normal().is_equal_approx(k): print(planes[k])`).
    - This data is not currently added to patch collisions as this is just one big trimesh collision. This may change later.


### TODO
- Lots of room for cutting down on duplicated code...
- Support importing BSP's from the projects "user" directory, along with custom textures (probably also pk3 support).
- Example project in a separate repository to demonstrate usage.
- idTech3 has a custom shader language which can override flags for surfaces, the addon currently doesn't support this.
- Return to Castle Wolfenstein and later Raven BSP (RBSP) versions support light styles (baked lights which can still have their color or intensity changed), probably other special features as well, the addon does not yet support this.
- Probably bugs to be squashed also. Feel free to open issues!
