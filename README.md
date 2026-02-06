# tech3bsp
An importer addon for Godot 4 to import an idTech3 BSP file as a Godot scene. Tested on all official builds `>= 4.4.1-stable` (including the current release version `4.6.stable.official`) as well as current dev build `4.7.dev`.

Currently supports "Quake 3 Arena", "Star Trek Voyager Elite Force" and "Return to Castle Wolfenstein" BSPs, with potential plans to add Ravens RBSP format (Jedi Outcast, etc.)
- This importer was written from scratch based on publicly available documentation of the Quake 3 BSP file format. No GPL code from the Quake 3 source release was copied or used. Work is based primarily on the unofficial specs found at https://www.mralligator.com/q3/.

If you want to work with Quake 1, Quake 2, Half-Life, or an alternate implementation of Quake 3 Arena BSP's, please check out https://github.com/jitspoe/godot_bsp_importer (which inspired this project).


### Features
- Brush, static mesh, and patch geometry with lightmap and vertex color support (requires custom shaders, examples included).
- Import light volumes (lightgrid) for lighting dynamic objects (also requires custom shaders, examples included).
- Imports billboard meshes (typically light flares) - this is still WIP, right now these are just saved as a MultiMesh.
- Material remapping, and fallback automatic materials from albedo texture + lightmap texture.
- Entity remapping via a ConfigFile, automatically adds your own configured scenes into the imported map.
- Includes simple example entity remap file, example shaders, and some lightweight scenes to demonstrate entity remapping.


### Installation and Usage
Place "addons/tech3bsp" into your Godot project (remember to include the "addons" directory itself), and enable it in "Project -> Project Settings -> Plugins". Any BSP files placed into your project directory will be automatically converted to Godot scenes.

If you are interested in using idTech3 light volumes (lightgrid) for lighting dynamic objects in your game, run the "setup.gd" script, which will add the necessary global uniforms for you (or add these manually):
- `light_grid_ambient`, sampler3D
- `light_grid_direct`, sampler3D
- `light_grid_cartesian`, sampler3D
- `light_grid_normalize`, vec3
- `light_grid_offset`, vec3
    - Make sure you have these globals available BEFORE doing imports: https://github.com/godotengine/godot/issues/77988

You can find very simple examples for shaders which support idTech3 lightmaps and light volumes, as well as an example entity remap ConfigFile and example scenes for BSP entities.
- The entity remap is done via a ConfigFile for simple reusability. It requires an `[entities]` section, and then the specific remapping is formatted as `classname="res://<path to a scene>"`
- The example entity scenes all use built-in scripts for simplicity and ease of removal if you don't need them. I _highly_ recommend using external scripts for all scenes you actually care about.

With regards to entity imports, the addon will try and push entity keys (e.g. `angles`, `wait`, etc.) to your scenes, so if you want to actually use those values remember to have an `@export var` with the same name as the entity key (i.e `@export var angles`, `@export var wait`), otherwise the value will just be ignored (the entity remap will still occur, it just won't have that property).
- A special note: for now these values are currently just passed as-is, mainly because idTech3 generally repurposes some properties for different results (e.g. `angles` on a `func_door` controls its movement direction, while on `info_player_start` it controls the rotation). For now handle what you want to do with the value on a per-class or per-scene basis, or maybe create a helper class to convert in the way that makes the most sense for your project. Will probably revisit this.

A note on the example shaders as well, these do _not_ have `ambient_light_disabled` since I believe having additional control over the ambient channel in a final scene is necessary for artistic purposes. As a result, when adding a BSP to a default scene, colors can look more "washed out" because your clear color is probably default grey and automatically applying ambient light via the `bg` source. Either edit the shader to disable ambient lighting, or add a WorldEnvironment and disable or configure ambient light to your needs.


### Import Options
**Unit Scale**
- Scale the resulting scene map size. The default value results in roughly equivalent idTech3 scaling. Defaults to 32.0.

**Light Brightness Multiplier**
- Multiply light brightness for imported lights (does not affect lightmaps or the lightgrid). Defaults to 1.0.

**Light Attenuation**
- OmniLight attenuation setting for imported lights, defaults to 1.0.
    - This setting will have no effect on lightmaps, only light entities (if lightmaps are also enabled, these can still be used for additional lighting/shadows on dynamic objects).
    - Setting this to higher values can result in substantially "smaller" lights due to the physical nature of the falloff curve.
    - A setting of 0.0 comes closer to matching Return to Castle Wolfensteins light falloff, while 1.0 is "hotter" towards the center, which is a bit more like Quake 3 Arena. As far as I'm aware there's currently no way to actually change the light falloff curve calculation via the editor, so these are just "close enough" approximations.
    - If you also have "Use Physical Light Units" enabled for your project, I _highly_ recommend turning the "Light Brightness Multiplier" down to something like `0.1` otherwise your lights will be extremely blown out.

**Entity Map**
- A path to a ConfigFile where entity remaps can be defined. Please check the "examples" directory for an example file.

**Print Missing Entities**
- Whether to print to the console when entity remaps are not present (this can be noisy on entity-heavy BSPs if you don't have remaps set up yet). Enabled by default.

**Materials Path**
- Path for material overrides. The BSP stores textures with a pattern similar to "textures/base/wall01" - the addon will reinterpret this to import Godot materials, so the pattern "/materials/{texture_name}.material" will load "/materials/base/wall01.material")
    - The path can be absolute (i.e. "res://materials/{texture_name}.material") or relative (i.e. "/materials/{texture_name}.material")

**Textures Path**
- Path to a directory of image files, primarily for fallback material generation purposes right now. Unlike the "Materials Path" option, this just needs to be a directory as it will test multiple image types. Defaults to "textures/"
    - All your file name casing should match how it appears in the BSP file.
    - As with materials, paths can be absolute (i.e. "res://textures/") or relative (i.e. "textures/" or "/textures/")

**Fallback Materials**
- Whether to generate fallback materials when a material is missing from the material path, either using an example shader supporting lightmaps and/or vertex colors, or a StandardMaterial3D if both vertex color and lightmap imports are disabled. Default true.

**Water, Slime, and Lava Scenes**
- PackedScene's for BSP liquids, please see the example scenes in the "examples" directory.

**Import Lightmaps**
- Whether to import pre-baked lighting data from the BSP. This will be stored in the scene itself, rather than saved as individual images to the "res" directory. Enabled by default.

**Import Lightgrid**
- Whether to import the lightgrid for lighting dynamic meshes, which is also stored with the saved scene. Default enabled.
    - If you import the lightgrid but NOT the lightmaps, you may need to introduce your own shader to use the lightgrid data. The example shader provided relies on the presence of a DirectionalLight3D and a `light()` shader stage to incorporate the lightgrid into the final result. Consider applying the lightgrid to the EMISSION channel in the `fragment()` stage instead, or apply at all stages of lighting instead of just directional, whatever works best for your project (doing it in `fragment()` also means you can use the `vertex_lighting` render_mode though, if you need that extra retro push).

**Import Vertex Colors**
- Whether to import baked vertex colors. Default enabled (as static meshes use it).

**Import Lights**
- If a map is compiled with either a `_keeplights` key enabled in worldspawn, or `-keeplights` in the BSP phase, light entities can be imported with this enabled. If lightmaps are also imported, these lights will not affect anything on the same culling layer as the map scene (simulating Godot's lightmapper behavior). Disabled by default.
    - A note on patches and specular highlights: right now, patches (curved geometry) do not fuse vertices, so specular highlights will look incorrect along the edges of each curved segment. This may be updated to fuse vertices later.

**Entity Shadow Light**
- The entire scene is lit via a generated DirectionalLight3D (see special notes below). This toggles whether this light will also cast shadows from meshes other than the map. These meshes will need to be on visibility layers other than 1 to do any shadowcasting. Disabled by default.

**Import Billboards**
- Whether to import lightflares. This is very WIP and more of a placeholder for now. Disabled by default.

**Split Mesh**
- Splits the mesh up by surfaces, though at some point this will be reworked to either split along a grid or somehow use vis data from the BSP itself. Godot works best with a small amount of meshes that contain a large amount of geometry, rather than many meshes each containing a small amount of geometry, so this is disabled by default.
    - Additional BSP models will automatically be "split" into their own MeshInstance3D's, as will patch geometry. Further, if a BSP model or a patch would generate more surfaces than `RenderingServer.MAX_MESH_SURFACES` it will be automatically split regardless of this setting.

**Occlusion Culling**
- Generates occlusion geometry, functional though still WIP as it can include geometry undesirable for culling (such as windows). Default disabled.

**Remove Skies**
- Allows skipping importing sky geometry, if you want to use Godot skies instead. Disabled by default.

**Patch Detail**
- How much tesselated geometry should be generated for patches, higher means more detailed. Default 5 (probably shouldn't go much higher than this).


### Special Notes, Hacks, and Limitations
Right now this whole addon is a bit of a hack, Godot doesn't technically support importing pre-baked lightmaps yet (see proposal https://github.com/godotengine/godot-proposals/issues/11116). If this proposal is ever accepted, this addon will be updated accordingly.
- At the moment the lightmap image data cannot be assigned to StandardMaterial3D, only ShaderMaterial types. The addon expects there to be a `lightmap_texture` uniform when importing lightmaps (this should work with VisualShaders as well).
- Since Godot doesn't support pre-baked lightmaps yet, there are basically three shader options for actually using idTech3 lightmaps: 
    - Use `render_mode unshaded` - functional, however no dynamic lighting can be used (no muzzle flashes or glowing plasma balls).
    - Use the `EMISSION` channel - allows dynamic lights, however dark decals will be invisible.
    - Use a custom `light()` stage and ignore light direction when `LIGHT_IS_DIRECTIONAL`. This is the method currently used in the example shaders, as this will work with decals and dynamic lights, as well as allow simple mesh directional shadows (if desired).
- The lightgrid requires that the BSP scene be centered and unrotated in your scene (so Transform3D.IDENTITY), otherwise the position lookups in shaders will be incorrect.
- Since Godot doesn't make it easy to intersect visible geometry with any sort of raycasts, idTech3 "flags" and "content_flags" data is stored into collision metadata as a Dictionary called `planes`, where the key is a quantized normal (Vector3) of the collision plane. This can be accessed via RayCasts and other physics collisions by using `get_meta("planes").` and a quantized normal from a collision as a key.
    - Example quantized normal function:
    
        ```
        func quantize_normal(normal: Vector3) -> Vector3i:
            const SNAP_STEP = 0.001
            const ZERO_THRESHOLD = 0.02
            
            normal = normal.normalized() # possibly unnecessary
            
            var vector3_snapped := Vector3(
                snapped(normal.x, SNAP_STEP),
                snapped(normal.y, SNAP_STEP),
                snapped(normal.z, SNAP_STEP)
            )
            
            for i in range(3):
                if abs(vector3_snapped[i]) < ZERO_THRESHOLD:
                    vector3_snapped[i] = 0.0 # avoid pesky floating point conversion madness
            
            return Vector3i(vector3_snapped * 1000)
        ```
        
    - Example function to get surface data via raycast:
        ```
        func get_surface(raycast: RayCast3D) -> Dictionary:
            if raycast.is_colliding():
                var target: Object = raycast.get_collider()
                var shape_id := raycast.get_collider_shape()
                var owner_id = target.shape_find_owner(shape_id)
                var shape = target.shape_owner_get_owner(owner_id)
                
                if shape.has_meta("planes"):
                    var planes: Dictionary = shape.get_meta("planes")
                    var hit_normal := raycast.get_collision_normal()
                    var convert_normal = (target.global_transform.basis.inverse() * hit_normal).normalized() # for rotating brushes
                    var key := quantize_normal(convert_normal)

                    if planes.has(key):
                        return planes[key]
                if shape.has_meta("patch"):
                    return shape.get_meta("patch")
            return {}
        ```
        
    - This approach allows a direct lookup rather than needing to loop through the `planes` Dictionary.
    - You can also get surface metadata off of rotated brushes by doing something like `(target.global_transform.basis.inverse() * hit_normal).normalized()` in your collision normal check (to account for the rotation).
    - Similar data can be found in patches with `get_meta("patch")`


### Map Compilation Suggestions
Since the addon currently doesn't actually do anything with vis data, you can skip the `vis` compilation stage for your own maps.

For compiling maps using your own Godot project, in order to guarantee correct texture scaling you may need to add something similar to `-fs_basepath "${GAME_DIR_PATH}" -fs_game "."` to your `q3map2` command line.
- `${GAME_DIR_PATH}` here would be your Godot project directory.

This is not a "hard and fast" compilation suggestion to follow, however I've had nice results with the following:
```
q3map2 -meta -samplesize 4 "mapfile"
q3map2 -light -samplesize 4 -patchshadows -samples 2 -filter -bounce 8 -bouncegrid "mapfile"
```
You can also pass `-nosRGBlight` on the `-light` compile which should generate linear colorspace lightmaps, which the addon will attempt to respect. These should have greater color range, similar to Godot's own lightmapper.

If you find that your lightgrid precision is abysmal, you can add the entity key `gridsize` to "worldspawn" in your map editor. It takes 3 values, the default is `64 64 128` however you can reduce this to something like `32 32 32` or even `16 16 16` for dramatically more precision, though be warned that the larger your map, the longer this will take to calculate (and the larger the resulting lightgrid texture3D's will be!).
- The default of `64 64 128` was likely intended mainly for human-sized models moving quickly through small arenas, hence the `128` at the end (so each cell is 64 units wide, 64 units deep, and 128 units tall).
- **ALSO** - make sure your maps are **SEALED!** Not only will unsealed maps not cull away outside geometry properly, it will make your lightgrid results look _really_ dark (to the point of appearing broken).


### Known Issues
- The imported map MUST be at the center of your scene and unrotated for the lightgrid to work. May work on this to be more dynamic later.
- Official Quake 3 Arena maps were compiled with light entities intact, however their radii are extremely small for some reason, so if you import one of these maps you may have to make some changes to account for this (if you want the light entities present, that is). This problem does not occur for maps compiled with modern q3map2.
- In order for lightmap imports to work, loaded materials need to be duplicated in the import process, otherwise the lightmap texture will be saved with the referenced material which can lead to incorrect lightmaps loading in other maps which rely on the same materials. As a result, any edits you make to materials post-import will require the map to be reimported in order to see those changes. If lightmap importing is disabled, materials will just be referenced rather than duplicated.
    - This could be worked around by applying lightmaps as a second pass, however this has a dramatic performance cost in Godot. This may be added as an import option later.
- Spotlight handling (when importing light entities) is very rudimentary, and `spot_range` likely can use some tweaking for better compatibility.
- Fog brushes are translated to Godot FogVolume nodes, and for now they should be axis-aligned (no brush rotation). Remember to provide your own FogMaterials in your `materials` directory for maximum fog-ness!
- Maps with terrain will load, however there is no special handling for idTech3 terrain shaders yet.


### Possible Issues
- "Return to Castle Wolfenstein" (IBSP v47) map imports _appear_ to have no issues, however this hasn't been tested extensively yet.
    - If you just want the RtCW "look" without the format, add `-wolf` to your `-light` phase of map compilation to get the same lighting falloff.


### TODO
- idTech3 has a custom shader language as well, the addon currently doesn't support this (aside from all the effects that happen during the actual map compilation stage, so you should still be using idTech3 shaders for map CREATION). High priority.
    - `q3map2` can generate light styles via shaders, so a shader parser would provide this as well. Very handy for more dynamic looking maps.
    - Team Arena introduced terrains and special terrain shaders, this is not a priority item however would also be cool to support.
- Skyboxes! Can probably just turn a skybox entity into a camera and then do some viewport and shader magic, since it will all be internal to the saved scene anyway. Medium priority (but also low hanging fruit).
- Support importing BSP's from the projects "user" directory, along with custom textures (probably also pk3 support). Medium priority.
- Example project in a separate repository to demonstrate usage. Medium priority.
- Maybe some room for additional cleanup, also need to hunt for anything that needs to be freed in some form during/after the import process. Low priority unless it's actually breaking things for people, then highest priority.
- Jolt Physics has an option to get the face index from a collision, though it increases the memory footprint, may support using this for plane metadata lookups in the future. Low priority.
- Probably numerous bugs to be squashed also. Feel free to open issues and PRs!
