extends Node3D

# --- Swarm Config (Editable in Inspector!) ---
@export var swarm_count: int = 100 # back off to 100 since preformance tanked with a realistic mesh
@export var instances_per_swarm: int = 1000
@export var spawn_radius: float = 50.0

var enable_colors: bool = true
var enable_compute: bool = true

var cam: Camera3D

# --- Low-Level Rendering Variables ---
var base_meshes: Array[Mesh] = []
var mm_rids: Array[RID] = []
var rs_instances: Array[RID] = []

# Keep references to the internal MultiMesh compute buffers for our copy pass later!
var mm_transform_buffers: Array[RID] = []
var mm_cmd_buffers: Array[RID] = []

# --- Compute Variables ---
var rd: RenderingDevice

var cull_shader: RID
var cull_pipeline: RID
var cull_uniform_set: RID

var cmd_shader: RID
var cmd_pipeline: RID
var cmd_uniform_set: RID

var entity_buffer: RID
var counter_buffer: RID # BUFFER B: Atomic Counter Array

# --- Mega-Buffers (To replace the single outputs) ---
var mega_transform_buffer: RID
var mega_cmd_buffer: RID

var push_constant_bytes := PackedByteArray()
var time_elapsed: float = 0.0
var compute_initialized: bool = false
var total_instances: int
var mesh_index_count: int = 0
var active_materials: Array[Material] = []

func _ready() -> void:
	total_instances = swarm_count * instances_per_swarm
	
	# uncomment this line to check for bottlenecks. it will attempt to run its fps as high as it can.
	# DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	
	_setup_camera()
	_setup_server_swarm()
	
	if enable_compute:
		# Wait until the Render Thread has fully processed and drawn a frame.
		# This guarantees the hardware RenderingDevice buffers now exist in VRAM.
		await RenderingServer.frame_post_draw
		_init_compute()

func _setup_camera() -> void:
	cam = Camera3D.new()
	cam.name = "SwarmCamera"
	
	add_child(cam)
	
	cam.position = Vector3(0, 0, 120)
	cam.look_at(Vector3.ZERO)
	cam.make_current()
	
func _extract_mesh_from_scene(scene_path: String) -> Mesh:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("Could not load scene: " + scene_path)
		var fallback := BoxMesh.new()
		fallback.size = Vector3.ONE
		return fallback

	var root := packed.instantiate()
	
	# Create a SurfaceTool to merge our meshes
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var nodes = root.find_children("*", "MeshInstance3D", true, false)
	
	# Don't forget the root itself, just in case
	if root is MeshInstance3D:
		nodes.append(root)

	var meshes_merged = 0
	for node in nodes:
		if node is MeshInstance3D and node.mesh != null:
			# Use the node's local transform so the leaves stay above the trunk!
			var xform = node.transform if node != root else Transform3D()
			
			# Append every surface of the mesh
			for surface_idx in node.mesh.get_surface_count():
				st.append_from(node.mesh, surface_idx, xform)
			
			meshes_merged += 1

	root.queue_free()

	if meshes_merged == 0:
		push_warning("No MeshInstance3D with mesh found in: " + scene_path)
		var fallback := BoxMesh.new()
		fallback.size = Vector3.ONE
		return fallback

	# Commit bakes everything we appended into a single ArrayMesh
	return st.commit()

func _setup_server_swarm() -> void:
	var scenario = get_world_3d().scenario
	var massive_aabb = AABB(Vector3(-10000, -10000, -10000), Vector3(20000, 20000, 20000))
	var mesh := _extract_mesh_from_scene("res://tree_2.tscn") #("res://player_capsule.tscn")
	
	# Extract the index count dynamically 
	var arrays = mesh.surface_get_arrays(0)
	var indices = arrays[Mesh.ARRAY_INDEX]
	if indices != null:
		mesh_index_count = indices.size()
	else:
		mesh_index_count = arrays[Mesh.ARRAY_VERTEX].size()
	
	# 1. Prepare the material ONCE outside the mesh
	var mat: StandardMaterial3D = null
	if enable_colors:
		mat = StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		active_materials.append(mat)
	
	for i in swarm_count:
		base_meshes.append(mesh)
		
		# 2. Create the MultiMesh completely on the RenderingServer
		var mm_rid = RenderingServer.multimesh_create()
		mm_rids.append(mm_rid)
		
		# 3. Allocate the memory WITH the indirect flag
		RenderingServer.multimesh_allocate_data(
			mm_rid, 
			instances_per_swarm, 
			RenderingServer.MULTIMESH_TRANSFORM_3D, 
			enable_colors, 
			false,         
			true           # use_indirect = true!
		)
		
		# 4. Assign the mesh
		RenderingServer.multimesh_set_mesh(mm_rid, mesh.get_rid())
		
		# 5. Populate initial zero-state data
		for j in instances_per_swarm:
			var t = Transform3D(Basis(), Vector3.ZERO)
			RenderingServer.multimesh_instance_set_transform(mm_rid, j, t)
			if enable_colors:
				RenderingServer.multimesh_instance_set_color(mm_rid, j, Color(1, 1, 1, 1))

		# 6. Create the instance and attach to world
		var rs_instance = RenderingServer.instance_create()
		rs_instances.append(rs_instance)
		RenderingServer.instance_set_base(rs_instance, mm_rid)
		RenderingServer.instance_set_scenario(rs_instance, scenario)
		
		# Prevent Frustum Culling
		RenderingServer.instance_set_custom_aabb(rs_instance, massive_aabb)
		
		if mat != null:
			RenderingServer.instance_geometry_set_material_override(rs_instance, mat.get_rid())

func _init_compute() -> void:
	rd = RenderingServer.get_rendering_device()
	if not rd:
		push_error("Compute unavailable.")
		return

	# 1. Compile BOTH Shaders
	var cull_file = load("res://swarm.glsl")
	cull_shader = rd.shader_create_from_spirv(cull_file.get_spirv())
	cull_pipeline = rd.compute_pipeline_create(cull_shader)
	
	var cmd_file = load("res://command_writer.glsl")
	cmd_shader = rd.shader_create_from_spirv(cmd_file.get_spirv())
	cmd_pipeline = rd.compute_pipeline_create(cmd_shader)

	# 2. Setup Entity Buffer (Buffer A) - ALL IN ONE TORNADO
	var entity_bytes := PackedByteArray()
	entity_bytes.resize(total_instances * 32)
	
	for i in total_instances:
		var offset = i * 32
		entity_bytes.encode_float(offset + 0, randf_range(-spawn_radius, spawn_radius))
		entity_bytes.encode_float(offset + 4, randf_range(-spawn_radius, spawn_radius))
		entity_bytes.encode_float(offset + 8, randf_range(-spawn_radius, spawn_radius))
		entity_bytes.encode_float(offset + 12, randf() * PI * 2.0)
		entity_bytes.encode_float(offset + 16, randf_range(10.0, 30.0))
		entity_bytes.encode_float(offset + 20, randf_range(5.0, 15.0))
		entity_bytes.encode_float(offset + 24, randf_range(10.0, 30.0))
		entity_bytes.encode_float(offset + 28, randf_range(0.5, 2.0))
		
	entity_buffer = rd.storage_buffer_create(entity_bytes.size(), entity_bytes)

	# 3. Setup Atomic Counter Buffer (Buffer B) - NOW AN ARRAY!
	var counter_bytes := PackedByteArray()
	counter_bytes.resize(4 * swarm_count) 
	counter_buffer = rd.storage_buffer_create(counter_bytes.size(), counter_bytes)

	# 4. Grab MultiMesh Buffers & Setup Mega Buffers
	mm_transform_buffers.clear()
	mm_cmd_buffers.clear()
	
	for mm_rid in mm_rids:
		mm_transform_buffers.append(RenderingServer.multimesh_get_buffer_rd_rid(mm_rid))
		mm_cmd_buffers.append(RenderingServer.multimesh_get_command_buffer_rd_rid(mm_rid))

	# Buffer C: Mega Transform Buffer
	var mega_transform_bytes := PackedByteArray()
	mega_transform_bytes.resize(total_instances * 64)
	mega_transform_buffer = rd.storage_buffer_create(mega_transform_bytes.size(), mega_transform_bytes)

	# Buffer D: Mega Command Buffer
	var mega_cmd_bytes := PackedByteArray()
	mega_cmd_bytes.resize(swarm_count * 20)
	mega_cmd_buffer = rd.storage_buffer_create(mega_cmd_bytes.size(), mega_cmd_bytes)

	# 5. Create Uniforms - CULLING PASS
	var u_entities = RDUniform.new()
	u_entities.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_entities.binding = 0
	u_entities.add_id(entity_buffer)

	var u_output = RDUniform.new()
	u_output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_output.binding = 1
	u_output.add_id(mega_transform_buffer) # USE MEGA BUFFER
	
	var u_counter_cull = RDUniform.new()
	u_counter_cull.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter_cull.binding = 2
	u_counter_cull.add_id(counter_buffer)

	cull_uniform_set = rd.uniform_set_create([u_entities, u_output, u_counter_cull], cull_shader, 0)
	
	# 6. Create Uniforms - COMMAND WRITER PASS
	var u_counter_cmd = RDUniform.new()
	u_counter_cmd.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_counter_cmd.binding = 0
	u_counter_cmd.add_id(counter_buffer)
	
	var u_cmd_output = RDUniform.new()
	u_cmd_output.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_cmd_output.binding = 1
	u_cmd_output.add_id(mega_cmd_buffer) # USE MEGA BUFFER
	
	cmd_uniform_set = rd.uniform_set_create([u_counter_cmd, u_cmd_output], cmd_shader, 0)
	
	push_constant_bytes.resize(112)
	compute_initialized = true

func _process(delta: float) -> void:
	if not compute_initialized: return
	
	time_elapsed += delta
	
	# 1. Pack Push Constants
	push_constant_bytes.encode_float(0, time_elapsed)
	push_constant_bytes.encode_float(4, delta)
	push_constant_bytes.encode_u32(8, total_instances)
	push_constant_bytes.encode_u32(12, instances_per_swarm)
	
	# Extract and Pack Camera Frustum Planes
	var planes = cam.get_frustum()
	var offset = 16
	for i in 6:
		var p: Plane = planes[i]
		push_constant_bytes.encode_float(offset + 0, p.normal.x)
		push_constant_bytes.encode_float(offset + 4, p.normal.y)
		push_constant_bytes.encode_float(offset + 8, p.normal.z)
		push_constant_bytes.encode_float(offset + 12, p.d)
		offset += 16
		
	# 2. Reset the atomic counter array BEFORE starting the compute list
	rd.buffer_clear(counter_buffer, 0, 4 * swarm_count)
	
	# --- PASS 1: Physics & Culling ---
	var cull_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cull_list, cull_pipeline)
	rd.compute_list_bind_uniform_set(cull_list, cull_uniform_set, 0)
	rd.compute_list_set_push_constant(cull_list, push_constant_bytes, push_constant_bytes.size())
	
	var workgroups_x = ceil(total_instances / 64.0)
	rd.compute_list_dispatch(cull_list, workgroups_x, 1, 1)
	
	rd.compute_list_add_barrier(cull_list)
	rd.compute_list_end()
	
	# --- PASS 2: Write Command Buffer ---
	var cmd_list = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cmd_list, cmd_pipeline)
	rd.compute_list_bind_uniform_set(cmd_list, cmd_uniform_set, 0)
	
	var cmd_pc := PackedByteArray()
	cmd_pc.resize(16)
	cmd_pc.encode_u32(0, swarm_count)
	cmd_pc.encode_u32(4, mesh_index_count)
	
	rd.compute_list_set_push_constant(cmd_list, cmd_pc, cmd_pc.size())
	
	var cmd_workgroups = ceil(swarm_count / 64.0) 
	rd.compute_list_dispatch(cmd_list, cmd_workgroups, 1, 1)
	
	rd.compute_list_add_barrier(cmd_list)
	rd.compute_list_end()

	# --- PASS 3: The Data Distributor (VRAM to VRAM) ---
	# Copy the partitioned data from our Mega-Buffers into Godot's native MultiMeshes.
	
	var transform_stride = 64 # 4 vec4s per transform (16 floats * 4 bytes)
	var swarm_byte_size = instances_per_swarm * transform_stride
	var cmd_byte_size = 20 # 5 uints * 4 bytes

	for i in swarm_count:
		# 1. Distribute Transforms (Buffer C slice -> MultiMesh i internal buffer)
		rd.buffer_copy(
			mega_transform_buffer,
			mm_transform_buffers[i],
			i * swarm_byte_size,
			0,
			swarm_byte_size
		)
		
		# 2. Distribute Draw Commands (Buffer D slice -> MultiMesh i command buffer)
		rd.buffer_copy(
			mega_cmd_buffer,
			mm_cmd_buffers[i],
			i * cmd_byte_size,
			0,
			cmd_byte_size
		)

func _exit_tree() -> void:
	# Clean up our manual RIDs!
	for rs_instance in rs_instances:
		if rs_instance.is_valid():
			RenderingServer.free_rid(rs_instance)
	for mm_rid in mm_rids:
		if mm_rid.is_valid():
			RenderingServer.free_rid(mm_rid)
