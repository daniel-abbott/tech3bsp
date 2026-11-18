# tech3bsp
An importer addon for Godot 4.7+ to import an idTech3 BSP file as a Godot scene. Tested on official builds `>= 4.7.2-stable` as well as current dev build `4.8.dev`.

Currently supports the IBSP 46 format (Q3A/TA. STV:EF, W:AoR, various idTech3 source port projects like Nexuiz/Xonotic), IBSP 47 (RtCW though this is less tested) and the Raven RBSP format (SoF2, JK2, JA).

- This importer was written from scratch based on publicly available documentation of the Quake 3 BSP file format. No GPL code from the Quake 3 source release was copied or used. Work is based primarily on the unofficial specs found at https://www.mralligator.com/q3/.

If you want to work with Quake 1, Quake 2, Half-Life, or an alternate implementation of Quake 3 Arena BSP's, please check out https://github.com/jitspoe/godot_bsp_importer (which inspired this project).


### Features
- Brush, static mesh, and patch geometry with lightmap and vertex color support (requires included custom shaders).
- Automatically create collision data with surface metadata assigned to each StaticBody3D.
- Import light volumes (lightgrid) for lighting dynamic objects (requires included custom shaders).
- Light styles (q3map2 lightstyle hack for IBSP, full light style support for RBSP)
- Deluxemapping support (baked light direction for specular highlights, requires included custom shaders).
    - Also a PBR GDShader for use with deluxemapping, use this to create on-disk materials to override generated materials when you want a full PBR deluxemapping look with imported lightmaps and light styles.
- Full shader converter from Q3/Raven shader scripts to GDShaders with optional save-to-disk (some DP shader extension support as well).
- Imports billboard meshes (typically light flares) - functional but could still use a better flare texture.
- Material remapping, and fallback automatic materials from albedo texture + lightmap texture.
- Entity remapping via a ConfigFile, automatically adds your own configured scenes into the imported map.
- Includes simple example entity remap file plus some lightweight entity scenes to demo remaps.
- Runtime BSP loading from PK3 files stored in your projects "user://" directory via a virtual file system.


### Installation and Usage
Place "addons/tech3bsp" into your Godot project (remember to include the "addons" directory itself), and enable it in "Project -> Project Settings -> Plugins". Any BSP files placed into your project directory will be automatically converted to Godot scenes.
- Remember to run the included "setup.gd" script to set the necessary shader globals!
    - Make sure you have these globals available BEFORE doing imports: https://github.com/godotengine/godot/issues/77988

- Entity remap to scene import is done via a ConfigFile for simple reusability. It requires an `[entities]` section, and then the specific remapping is formatted as `classname="res://<path to a scene>"`

With regards to entity imports, the addon will try and push entity keys (e.g. `angles`, `wait`, etc.) to your scenes, so if you want to actually use those values remember to have an `@export var` with the same name as the entity key (i.e `@export var angles`, `@export var wait`), otherwise the value will just be ignored (the entity remap will still occur, it just won't have that property).


### Special Notes, Hacks, and Limitations
Right now this whole addon is a bit of a hack, Godot doesn't technically support importing pre-baked lightmaps yet (see proposal https://github.com/godotengine/godot-proposals/issues/11116). If this proposal is ever accepted, this addon will be updated accordingly.
- At the moment the lightmap image data cannot be assigned to StandardMaterial3D, only ShaderMaterial types. The addon expects there to be a `lightmap_texture` uniform when importing lightmaps (this should work with VisualShaders as well).
- The lightgrid requires that the BSP scene be centered and unrotated in your scene (so Transform3D.IDENTITY), otherwise the position lookups in shaders will be incorrect.


### Known Issues
- The imported map MUST be at the center of your scene and unrotated for the lightgrid to work. May work on this to be more dynamic later.
- Official Quake 3 Arena maps were compiled with light entities intact, however their radii are extremely small for some reason, so if you import one of these maps you may have to make some changes to account for this (if you want the light entities present, that is). This problem does not occur for maps compiled with modern q3map2.
- In order for lightmap imports to work, loaded materials need to be duplicated in the import process, otherwise the lightmap texture will be saved with the referenced material which can lead to incorrect lightmaps loading in other maps which rely on the same materials. As a result, any edits you make to materials post-import will require the map to be reimported in order to see those changes. If lightmap importing is disabled, materials will just be referenced rather than duplicated.
    - This could be worked around by applying lightmaps as a second pass, however this has a dramatic performance cost in Godot. This may be added as an import option later.


### Possible Issues
- Probably many, this project has grown quite a bit in complexity with the addition of the shader parser, so please do report any issues encountered!


### TODO
- Example project in a separate repository to demonstrate usage. Medium priority.
- Probably numerous bugs to be squashed also. Feel free to open issues and PRs!
