`default_nettype none

module ROB (

	// Clock and synchronous active high reset
	input  logic clk, reset,
	
	// Incoming entry signals
	input  logic [PPL_WIDTH-1:0] inserted_mask,
	input  rob_entry_t [PPL_WIDTH-1:0] inserted_entries,
	output logic [PPL_WIDTH-1:0][ROB_BIT-1:0] inserted_index,

	// Executed instruction signals
	input  logic [PPL_WIDTH-1:0] executed_mask,
	input  logic [PPL_WIDTH-1:0][ROB_BIT-1:0] executed_index,
	
	// Output entry signals
	output logic [PPL_WIDTH-1:0] removed_mask,
    output logic [PPL_WIDTH-1:0] committed_mask,
	output rob_entry_t [PPL_WIDTH-1:0] removed_entries,
	
	// Full flag
	output logic  full,

	// Branch signals
	input  logic  flush_en,
	input  logic [ROB_BIT-1:0] flush_index,

	// Current head of the ROB
	output logic [ROB_BIT-1:0] rob_head
);

    /********************
    * ADD YOUR CODE HERE
    *********************/

	rob_entry_t [ROB_SIZE -1] rob_buffer_queue, next_rob_buffer_queue;
	logic [ROB_BIT-1:0] rob_insert_index, insert_count, remove_count;
	logic [ROB_BIT-1:0] rob_remove_index;

	always_comb begin
		insert_count = '0;
		foreach (inserted_mask[i]) begin
        	insert_count += inserted_mask[i]; 
    	end
		remove_count = '0;
		foreach (removed_mask[i]) begin
			remove_count += removed_mask[i];
		end
	end

	always_ff @(posedge clk) begin
		if (reset) rob_insert_index <= '0;
		else rob_insert_index <= rob_insert_index + insert_count;

		if (reset) rob_remove_index <= '0;
		else rob_remove_index <= rob_remove_index + remove_count;
	end

	always_ff @(posedge clk) begin
		if (reset) rob_buffer_queue <= '0;
		else rob_buffer_queue <= next_rob_buffer_queue;
	end

	always_comb begin
		next_rob_buffer_queue = rob_buffer_queue;
		inserted_index = '0;	
		committed_mask = '0;
		for (int i = 0; i < PPL_WIDTH; i++) begin
			if (inserted_mask[i]) begin
				next_rob_buffer_queue[rob_insert_index+i] = inserted_entries[i];
				next_rob_buffer_queue[rob_insert_index+i].is_completed = 1'b0;
				next_rob_buffer_queue[rob_insert_index+i].valid = 1'b1;
				inserted_index[i] = rob_insert_index + i;
			end
		end
	
		for (int i = 0; i < PPL_WIDTH; i++) begin
			if (executed_mask[i]) next_rob_buffer_queue[executed_index[i]].is_completed = 1'b1;
		end
		
	
		committed_mask[0] = rob_buffer_queue[rob_remove_index].is_completed & rob_buffer_queue[rob_remove_index].valid;
		removed_entries[0] = rob_buffer_queue[rob_remove_index];

		for (int i = 1; i < PPL_WIDTH; i++) begin
			committed_mask[i] = committed_mask[i-1] & 
			rob_buffer_queue[rob_remove_index+i].is_completed & 
			rob_buffer_queue[rob_remove_index+i].valid;
			removed_entries[i] = rob_buffer_queue[rob_remove_index+i];
		end
	end

	assign rob_head = rob_remove_index;
	assign removed_mask = committed_mask;



	logic [$clog2(ROB_SIZE):0] entry_count, comb_entry_count;
	assign comb_entry_count = entry_count + insert_count - remove_count;

	always_ff @(posedge clk) begin
		if (reset) entry_count <= '0;
		else entry_count <= comb_entry_count;
	end

	assign full = (ROB_SIZE - comb_entry_count) < PPL_WIDTH;	
endmodule: ROB
