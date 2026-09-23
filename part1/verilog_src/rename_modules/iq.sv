`default_nettype none

module IQ (

	// Clock and synchronous active high reset
	input  logic clk, reset,

	// Incoming entry signals
	input  logic [PPL_WIDTH-1:0] inserted_mask,
	input  iq_entry_t [PPL_WIDTH-1:0] inserted_entries,

	// Executed instruction signals
	input  logic [PPL_WIDTH-1:0] executed_mask,
	input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] executed_preg,

	// Issued entry signals
	output logic [PPL_WIDTH-1:0] issued_mask,
    output iq_entry_t [PPL_WIDTH-1:0] issued_entries,

	// Full flag
	output logic  full,

	// Branch signals
	input  logic  flush_en,
	input  logic [ROB_BIT-1:0] flush_index,
	input  logic [ROB_BIT-1:0] rob_head
);
    // IQ entries
    iq_entry_t [IQ_SIZE-1:0] entries, inserted_entry;
    logic [IQ_SIZE-1:0] issued, inserted;
    for (genvar X = 0; X < IQ_SIZE; X++) begin
        always_ff @(posedge clk) begin
            if (reset)
                entries[X] <= 'd0;
            else if (issued[X])
                // Currently prevents same-cycle issue and insert
                entries[X].valid <= 1'b0;
            else if (inserted[X]) begin
                // Some assumptions here on the validity of inserted_entry data
                // Currently can not insert and update executed_preg on same cycle
                entries[X] <= inserted_entry[X];
                entries[X].valid <= 1'b1;
            end else if (entries[X].valid) begin
                // Check for preg match
                for (int Y = 0; Y < PPL_WIDTH; Y++) begin
                    if ((entries[X].src1 == executed_preg[Y]) && executed_mask[Y])
                        entries[X].src1_ready <= 1'b1;
                    if ((entries[X].src2 == executed_preg[Y]) && executed_mask[Y])
                        entries[X].src2_ready <= 1'b1;
                end
            end
        end
    end

    // Creating a round-robin counter for issuing
    logic [IQ_BIT-1:0] rr_count;
    logic [PPL_WIDTH-1:0][IQ_BIT-1:0] winners;
    logic [$clog2(PPL_WIDTH):0] num_wins;
    always_ff @(posedge clk) begin
        if (reset)
            rr_count <= 'd0;
        else if (num_wins > 0)
            rr_count <= winners[num_wins-1] + 'd1;
    end

    // Issued and inserted generation logic
    int num_inserts, idx;
    always_comb begin
        // Issue output and tracking setting
        num_wins = 'd0;
        winners = 'd0;
        issued_mask = 'd0;
        issued_entries = 'd0;
        issued = 'd0;

        // Insert output and tracking setting
        num_inserts = 0;
        inserted = 'd0;
        inserted_entry = 'd0;
        for (int i = 0; i < IQ_SIZE; i++) begin
            idx = (rr_count + i) % IQ_SIZE;

            // Performing issue
            if (entries[idx].src1_ready && entries[idx].src2_ready && entries[idx].valid && num_wins < PPL_WIDTH) begin
                winners[num_wins] = idx;
                issued_mask[num_wins] = 1'b1;
                issued_entries[num_wins] = entries[idx];
                issued[idx] = 1'b1;
                num_wins += 1;
            end

            // Performing insertion
            if (~entries[idx].valid && num_inserts < PPL_WIDTH && inserted_mask[num_inserts]) begin
                inserted_entry[idx] = inserted_entries[num_inserts];
                inserted[idx] = 1'b1;
                // Check if any dependencies come back on the cycle the instruction is inserted
                for (int j = 0; j < PPL_WIDTH; j++) begin
                    if (inserted_entries[num_inserts].src1 == executed_preg[j] && executed_mask[j])
                        inserted_entry[idx].src1_ready = 1'b1;
                    if (inserted_entries[num_inserts].src2 == executed_preg[j] && executed_mask[j])
                        inserted_entry[idx].src2_ready = 1'b1;
                end
                num_inserts += 1;
            end
        end
    end

    // Full generation
    always_comb begin
        int occupied_count = 0;
        for (int i = 0; i < IQ_SIZE; i++) begin
            if (entries[i].valid)
                occupied_count += 1;
        end
        full = (occupied_count + PPL_WIDTH > IQ_SIZE);
    end
endmodule: IQ
