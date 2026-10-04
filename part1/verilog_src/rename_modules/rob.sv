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

	rob_entry_t [ROB_SIZE-1:0] rob_buffer_queue, next_rob_buffer_queue;
	logic [ROB_BIT-1:0] rob_insert_index, insert_count, remove_count;
	logic [ROB_BIT-1:0] rob_remove_index;
	logic flushing, next_flush;
	logic [ROB_BIT-1:0] flush_count, next_flush_count, flush_index_reg;


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
		if (reset) flushing <= '0;
		else flushing <= next_flush;
	end

	always_ff @(posedge clk) begin
		if (reset) rob_insert_index <= '0;
		else if (flushing) rob_insert_index <= rob_insert_index - remove_count;
		else if (!flush_en) rob_insert_index <= rob_insert_index + insert_count;

		if (reset) rob_remove_index <= '0;
		else rob_remove_index <= rob_remove_index + $countones(committed_mask);
	end

	always_ff @(posedge clk) begin
		if (reset) rob_buffer_queue <= '0;
		else rob_buffer_queue <= next_rob_buffer_queue;
	end

	always_ff @(posedge clk) begin
		if (reset) flush_count <= '0;
		else flush_count <= next_flush_count;
	end

	always_ff @(posedge clk) begin
		if (reset)flush_index_reg <= '0;
		else if (flush_en) flush_index_reg <= flush_index;
	end

		logic [ROB_BIT-1:0] ins_idx, rem_idx;   // 7-bit, so they wrap 127 -> 0
	logic               keep_going;

	always_comb begin
		next_rob_buffer_queue = rob_buffer_queue;
		inserted_index  = '0;
		committed_mask  = '0;
		removed_entries = '0;
		keep_going = 1'b1;
		removed_mask = '0;
		if (!flushing) begin
			for (int i = 0; i < PPL_WIDTH; i++) begin
				rem_idx            = rob_remove_index + ROB_BIT'(i);
				committed_mask[i]  = keep_going
									& rob_buffer_queue[rem_idx].valid
									& rob_buffer_queue[rem_idx].is_completed;
				keep_going         = committed_mask[i];   // stop at the first unfinished one
				removed_entries[i] = rob_buffer_queue[rem_idx];
				if (committed_mask[i])
					next_rob_buffer_queue[rem_idx].valid = 1'b0;   // Bug 3 fix: free the slot
				removed_mask = committed_mask;
			end
		end
		else begin
			for (int i = 0; i < PPL_WIDTH; i++) begin
				rem_idx = rob_insert_index - ROB_BIT'(i)-1;
				removed_entries[i] = rob_buffer_queue[rem_idx];

				removed_mask[i] = (rob_buffer_queue[rem_idx].valid) & (rem_idx > flush_index_reg);
				next_rob_buffer_queue[rem_idx].valid = ~removed_mask[i];
			end
		end
		// 2) Insert at the tail (wrapping)
		if (!flush_en) begin
			for (int i = 0; i < PPL_WIDTH; i++) begin
				if (inserted_mask[i]) begin
					ins_idx                                    = rob_insert_index + ROB_BIT'(i);
					next_rob_buffer_queue[ins_idx]              = inserted_entries[i];
					next_rob_buffer_queue[ins_idx].is_completed = 1'b0;
					next_rob_buffer_queue[ins_idx].valid        = 1'b1;
					inserted_index[i]                           = ins_idx;
				end
			end
		end

		assign next_flush = (flush_en) | (flushing & (flush_count > 4));
		// 3) Mark executed entries as completed
		for (int i = 0; i < PPL_WIDTH; i++) begin
			if (executed_mask[i])
				next_rob_buffer_queue[executed_index[i]].is_completed = 1'b1;
		end
	end
	always_comb begin
		next_flush_count = 0;
		if (flush_en) begin
			if (rob_insert_index>flush_index) next_flush_count = rob_insert_index - flush_index -1;
			else next_flush_count = ROB_SIZE - (flush_index - rob_insert_index) -1;
		end
		else if (flushing) next_flush_count = flush_count - remove_count;
	end
	assign rob_head = rob_remove_index;

	logic [$clog2(ROB_SIZE):0] entry_count, comb_entry_count;
	assign comb_entry_count = entry_count + insert_count - remove_count;

	always_ff @(posedge clk) begin
		if (reset) entry_count <= '0;
		else entry_count <= comb_entry_count;
	end

	assign full = (ROB_SIZE - entry_count) < PPL_WIDTH;
endmodule: ROB