#[compute]
#version 450

// -----------------------------------------------------------------------------
// 1. DATA STRUCTURES
// -----------------------------------------------------------------------------
struct Entity {
	vec4 position; // xyz = pos, w = phase/random offset
	vec4 velocity; // xyz = velocity, w = speed multiplier
};
// The Godot MultiMesh 3D Transform format (12 floats, strict row-major)
// UPDATED: Now 64 bytes to match use_colors = true
struct MultiMeshTransform {
	vec4 row0; // basis.x.x, basis.y.x, basis.z.x, origin.x
	vec4 row1; // basis.x.y, basis.y.y, basis.z.y, origin.y
	vec4 row2; // basis.x.z, basis.y.z, basis.z.z, origin.z
	vec4 color;
};

// -----------------------------------------------------------------------------
// 2. BUFFERS
// -----------------------------------------------------------------------------
layout(set = 0, binding = 0, std430) restrict buffer EntityBuffer { Entity entities[]; };
layout(set = 0, binding = 1, std430) writeonly buffer TransformOutput { MultiMeshTransform final_transforms[]; };

// Buffer B: Array of Atomic Counters (One for each swarm!)
layout(set = 0, binding = 2, std430) restrict buffer CounterBuffer { uint visible_counts[]; }; 

// -----------------------------------------------------------------------------
// 3. PUSH CONSTANTS
// -----------------------------------------------------------------------------
layout(push_constant, std430) uniform Params {
	float time;
	float delta;
	uint total_instances;
	uint instances_per_swarm;
	vec4 planes[6];
} params;

// -----------------------------------------------------------------------------
// 4. THE KERNEL
// -----------------------------------------------------------------------------
// A 1x1x1 box has a bounding sphere radius of roughly 0.866. 
// We use 1.0 to give a tiny bit of safe padding.
bool is_visible(vec3 pos, float radius) {
	for (int i = 0; i < 6; i++) {
        // Godot's frustum planes face OUTWARD. 
        // If the distance along the normal is greater than 'd' + radius, it's off-screen.
        float dist = dot(params.planes[i].xyz, pos) - params.planes[i].w;
		if (dist > radius) return false;
	}
	return true;
}

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

void main() {
	uint idx = gl_GlobalInvocationID.x;
	if (idx >= params.total_instances) { return; }

	// --- MEGA-BUFFER MATH (DYNAMIC!) ---
	uint swarm_id = idx / params.instances_per_swarm; 

	Entity e = entities[idx];

	// --- HARD-CODED MOVEMENT LOGIC ---
    // Make them swirl in a massive sine-wave tornado
    e.position.x += sin(params.time * e.velocity.w + e.position.w) * e.velocity.x * params.delta;
	e.position.y += e.velocity.y * params.delta;
	e.position.z += cos(params.time * e.velocity.w + e.position.w) * e.velocity.z * params.delta;
	if (e.position.y > 100.0) {
		e.position.y = -100.0;
	}

	entities[idx] = e;

	// --- PARTITIONED COMPACTION ---
	if (is_visible(e.position.xyz, 1.0)) {
		// 1. Claim a slot in THIS SPECIFIC SWARM'S counter
		uint local_slot = atomicAdd(visible_counts[swarm_id], 1);

		// 2. Calculate the global offset in the Mega Transform Buffer
		uint global_dst = (swarm_id * params.instances_per_swarm) + local_slot;

		// 3. Generate a unique base color for this specific swarm!
		float total_swarms = float(params.total_instances) / float(params.instances_per_swarm);
		float hue = float(swarm_id) / total_swarms; 
		
		vec3 swarm_color = vec3(
			0.5 + 0.5 * cos(6.28318 * (hue + 0.0)),
			0.5 + 0.5 * cos(6.28318 * (hue + 0.33)),
			0.5 + 0.5 * cos(6.28318 * (hue + 0.67))
		);

		// Keep a little bit of the height shading for depth
		float normalized_height = (e.position.y + 100.0) / 200.0;
		vec3 final_rgb = mix(swarm_color * 0.2, swarm_color, normalized_height);

		// Write exclusively to the compacted index!
		final_transforms[global_dst].row0 = vec4(1.0, 0.0, 0.0, e.position.x);
		final_transforms[global_dst].row1 = vec4(0.0, 1.0, 0.0, e.position.y);
		final_transforms[global_dst].row2 = vec4(0.0, 0.0, 1.0, e.position.z);
		final_transforms[global_dst].color = vec4(final_rgb, 1.0);
	}
}