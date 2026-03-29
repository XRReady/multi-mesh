#[compute]
#version 450

// Buffer B: The Array of Counters written by swarm.glsl
layout(set = 0, binding = 0, std430) restrict readonly buffer CounterBuffer { uint visible_counts[]; };

// Buffer D: The Mega Command Buffer
layout(set = 0, binding = 1, std430) writeonly buffer CommandBuffer { uint commands[]; };

// --- NEW DYNAMIC PUSH CONSTANTS ---
layout(push_constant, std430) uniform Params {
	uint swarm_count;
	uint pad1;
	uint pad2;
	uint pad3;
} params;

// Run 64 threads per workgroup. We dispatch enough workgroups to hit the dynamic swarm_count.
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

void main() {
	uint swarm_id = gl_GlobalInvocationID.x;
	
	// Ensure we don't process out-of-bounds threads based on our dynamic variable
	if (swarm_id >= params.swarm_count) { return; } 

	// Each draw command requires exactly 5 uints.
	uint cmd_offset = swarm_id * 5; 

	// Godot BoxMesh has 36 indices. If you randomize meshes, you'll need to pass the index counts 
	// in via a separate buffer or push constants later. For now, 36 is safe for the BoxMesh baseline.
	commands[cmd_offset + 0] = 36;                     // indexCount
	commands[cmd_offset + 1] = visible_counts[swarm_id]; // instanceCount
	commands[cmd_offset + 2] = 0;                      // firstIndex
	commands[cmd_offset + 3] = 0;                      // vertexOffset
	commands[cmd_offset + 4] = 0;                      // firstInstance
}