`default_nettype none

module RRU (

	// Clock and synchronous active high reset
	input  logic clk, reset,
	
	// Incoming entry signals
	input  logic [PPL_WIDTH-1:0] inserted_mask,
	input  instruction_t [PPL_WIDTH-1:0] inserted_entries,

	// Committed/Removed instruction signals
	input  logic [PPL_WIDTH-1:0] committed_mask,
	input  logic [PPL_WIDTH-1:0] removed_mask,
	input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] removed_preg,
	input  logic [PPL_WIDTH-1:0][ARCH_BIT-1:0] removed_areg,

	input  logic [PPL_WIDTH-1:0]                executed_mask,
    input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0]  executed_preg,

	// Which removed entries were branches
	// A branch releases its checkpoint when it commits.
	input  logic [PPL_WIDTH-1:0] removed_is_branch,
	
	// Renamed entry signals
	output logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] renamed_preg,
	output rob_entry_t [PPL_WIDTH-1:0] renamed_rob_entries,
	output iq_entry_t [PPL_WIDTH-1:0] renamed_iq_entries,

	// PRF FSMs and archRAT are visible to RRU
	input  logic [PHYS_REG-1:0][1:0] preg_states,
	input  logic [ARCH_REG-1:0][PHYS_BIT-1:0] archRAT,

	// ROB slot assigned to each incoming instruction this cycle
	input  logic [PPL_WIDTH-1:0][ROB_BIT-1:0] inserted_index,

	// full flag
	output logic full,

	// Stall signal
	output logic stall,

	// Branch signals
	input  logic  flush_en,
	input  logic [ROB_BIT-1:0] flush_index
);

	localparam int CKPT_NUM = 8;               // power of 2, >= PPL_WIDTH
	localparam int CKPT_BIT = $clog2(CKPT_NUM);

	logic [CKPT_NUM-1:0][ARCH_REG-1:0][PHYS_BIT-1:0] ckpt_rat;
	logic [CKPT_NUM-1:0][ROB_BIT-1:0]                ckpt_rob;   // tag = ROB slot of the branch
	logic [CKPT_BIT-1:0] ckpt_head;                              // oldest live snapshot
	logic [CKPT_BIT:0]   ckpt_count;

    localparam logic [1:0] S_AVAIL = 2'b00;
    localparam logic [1:0] S_RNV   = 2'b01;
    localparam logic [1:0] S_RV    = 2'b10;
    localparam logic [1:0] S_ARCH  = 2'b11;
 
    // Speculative RAT
    logic [ARCH_REG-1:0][PHYS_BIT-1:0] specRAT;
 
    // Free-register picker: lane i gets the (i+1)-th lowest AVAIL preg.
    // Simple serial version; a good optimization target for Task 7.

    logic [PHYS_REG-1:0]                avail_vec;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] free_preg;
    logic [PPL_WIDTH-1:0]               free_found;
 
    always_comb begin
        for (int p = 0; p < PHYS_REG; p++)
            avail_vec[p] = (preg_states[p] == S_AVAIL);
 
        for (int i = 0; i < PPL_WIDTH; i++) begin
            free_found[i] = 1'b0;
            free_preg[i]  = '0;
            for (int p = 0; p < PHYS_REG; p++) begin
                if (avail_vec[p] && !free_found[i]) begin
                    free_found[i] = 1'b1;
                    free_preg[i]  = PHYS_BIT'(p);
                end
            end
            if (free_found[i])
                avail_vec[free_preg[i]] = 1'b0;   // hide it from later lanes
        end
    end
 
    // Full when fewer than PPL_WIDTH free pregs, i.e. the last lane found none.
    assign full  = !free_found[PPL_WIDTH-1];
 
    // Source renaming with intra-batch forwarding
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] src1_p, src2_p;
    logic [PPL_WIDTH-1:0]               src1_fwd, src2_fwd;
    logic [PPL_WIDTH-1:0]               src1_rdy, src2_rdy;
 
    always_comb begin
        for (int i = 0; i < PPL_WIDTH; i++) begin
            // Default: latest mapping from previous cycles
            src1_p[i]   = specRAT[inserted_entries[i].src1];
            src2_p[i]   = specRAT[inserted_entries[i].src2];
            src1_fwd[i] = 1'b0;
            src2_fwd[i] = 1'b0;
 
            // Older lanes in the same batch override (later j = younger = wins)
            for (int j = 0; j < PPL_WIDTH; j++) begin
                if (j < i && inserted_mask[j]) begin
                    if (inserted_entries[j].dest == inserted_entries[i].src1) begin
                        src1_p[i]   = free_preg[j];
                        src1_fwd[i] = 1'b1;
                    end
                    if (inserted_entries[j].dest == inserted_entries[i].src2) begin
                        src2_p[i]   = free_preg[j];
                        src2_fwd[i] = 1'b1;
                    end
                end
            end
 
            // Ready if the producer already finished (RV/ARCH) or is being
            // broadcast right now. Forwarded sources are never ready.
            src1_rdy[i] = !src1_fwd[i] &&
                          (preg_states[src1_p[i]] == S_RV || preg_states[src1_p[i]] == S_ARCH);
            src2_rdy[i] = !src2_fwd[i] &&
                          (preg_states[src2_p[i]] == S_RV || preg_states[src2_p[i]] == S_ARCH);
            for (int k = 0; k < PPL_WIDTH; k++) begin
                if (executed_mask[k] && !src1_fwd[i] && executed_preg[k] == src1_p[i]) src1_rdy[i] = 1'b1;
                if (executed_mask[k] && !src2_fwd[i] && executed_preg[k] == src2_p[i]) src2_rdy[i] = 1'b1;
            end
        end
    end
 
    // Build ROB / IQ entries
    always_comb begin
        for (int i = 0; i < PPL_WIDTH; i++) begin
            renamed_preg[i] = free_preg[i];
 
            renamed_rob_entries[i].areg         = inserted_entries[i].dest;
            renamed_rob_entries[i].preg         = free_preg[i];
            renamed_rob_entries[i].inst_ID      = inserted_entries[i].inst_ID;
            renamed_rob_entries[i].is_completed = 1'b0;
            renamed_rob_entries[i].is_branch    = inserted_entries[i].is_branch;
            renamed_rob_entries[i].valid        = inserted_mask[i];
 
            renamed_iq_entries[i].rob_index  = inserted_index[i];
            renamed_iq_entries[i].inst_ID    = inserted_entries[i].inst_ID;
            renamed_iq_entries[i].src1       = src1_p[i];
            renamed_iq_entries[i].src2       = src2_p[i];
            renamed_iq_entries[i].src1_ready = src1_rdy[i];
            renamed_iq_entries[i].src2_ready = src2_rdy[i];
            renamed_iq_entries[i].valid      = inserted_mask[i];
        end
    end


	logic [PPL_WIDTH-1:0][ARCH_REG-1:0][PHYS_BIT-1:0] lane_rat;
	logic [PPL_WIDTH-1:0]               br_push;
	logic [PPL_WIDTH-1:0][CKPT_BIT-1:0] br_slot;
	logic [CKPT_BIT:0]                  n_push;

	always_comb begin
		logic [ARCH_REG-1:0][PHYS_BIT-1:0] cur;
		cur = specRAT;  n_push = '0;
		for (int i = 0; i < PPL_WIDTH; i++) begin
			if (inserted_mask[i]) cur[inserted_entries[i].dest] = free_preg[i];
			lane_rat[i] = cur;
			br_push[i]  = inserted_mask[i] && inserted_entries[i].is_branch;
			br_slot[i]  = ckpt_head + CKPT_BIT'(ckpt_count) + CKPT_BIT'(n_push);
			if (br_push[i]) n_push++;
		end
	end
	
	logic [CKPT_BIT:0] n_pop;
	always_comb begin
		n_pop = '0;
		for (int i = 0; i < PPL_WIDTH; i++)
			if (removed_mask[i] && committed_mask[i] && removed_is_branch[i]) n_pop++;
	end

	logic                flush_found;
	logic [CKPT_BIT-1:0] flush_slot;
	logic [CKPT_BIT:0]   flush_keep;    // snapshots kept: everything up to and including the branch
	always_comb begin
		flush_found = 0; flush_slot = '0; flush_keep = '0;
		for (int r = 0; r < CKPT_NUM; r++) begin
			logic [CKPT_BIT-1:0] s;
			s = ckpt_head + CKPT_BIT'(r);
			if (r < ckpt_count && !flush_found && ckpt_rob[s] == flush_index) begin
				flush_found = 1; flush_slot = s; flush_keep = (CKPT_BIT+1)'(r) + 1;
			end
		end
	end


	assign stall = flush_en | (committed_mask != removed_mask) | ((CKPT_NUM - ckpt_count) < PPL_WIDTH);

	always_ff @(posedge clk) begin
		if (reset) begin
			for (int a = 0; a < ARCH_REG; a++) specRAT[a] <= PHYS_BIT'(a);
			ckpt_head <= '0;  ckpt_count <= '0;
		end else if (flush_en) begin
			// Discard this cycle's batch: no specRAT writes, no snapshot push.
			if (flush_found) specRAT <= ckpt_rat[flush_slot];
			ckpt_head  <= ckpt_head + CKPT_BIT'(n_pop);
			ckpt_count <= (flush_found ? flush_keep : ckpt_count) - n_pop;   // the branch's own snapshot stays until it commits
		end else begin
			for (int i = 0; i < PPL_WIDTH; i++) begin
				if (inserted_mask[i]) specRAT[inserted_entries[i].dest] <= free_preg[i];
				if (br_push[i]) begin
					ckpt_rat[br_slot[i]] <= lane_rat[i];
					ckpt_rob[br_slot[i]] <= inserted_index[i];
				end
			end
			ckpt_head  <= ckpt_head + CKPT_BIT'(n_pop);
			ckpt_count <= ckpt_count + n_push - n_pop;
		end
	end

	
endmodule: RRU