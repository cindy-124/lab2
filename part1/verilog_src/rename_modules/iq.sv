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
    logic [ROB_BIT-1:0] adjusted_head;
    assign adjusted_head = flush_index - rob_head;
    for (genvar X = 0; X < IQ_SIZE; X++) begin
        always_ff @(posedge clk) begin
            if (reset)
                entries[X] <= 'd0;
            else if (flush_en) begin
                // flush_index may or may not be relative
                if (entries[X].rob_index - rob_head > adjusted_head)
                    entries[X].valid <= 1'b0;
            end else if (issued[X])
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
    int num_inserts;
    logic [IQ_BIT-1:0] idx;
    logic [PPL_WIDTH-1:0][IQ_SIZE-1:0] val_map;
    logic [PPL_WIDTH-1:0][IQ_SIZE-1:0] ins_map;
    logic [PPL_WIDTH-1:0][IQ_BIT-1:0] idx_map;
    always_comb begin
        // Issue output and tracking setting
        num_wins = 'd0;
        winners = 'd0;
        issued_mask = 'd0;
        for (int i = 0; i < IQ_SIZE; i++) begin
            val_map[0][i] = entries[i].valid && entries[i].src1_ready && entries[i].src2_ready;
        end
        for (int i = 0; i < PPL_WIDTH; i++) begin
            for (logic [IQ_BIT:0] j = 0; j < IQ_SIZE; j++) begin
                idx = rr_count + j;
                if (val_map[i][idx]) begin
                    winners[i] = idx;
                    issued_mask[i] = 1'b1;
                    num_wins += 1'b1;
                    break;
                end
            end

            // Set map for next stage
            if (i < PPL_WIDTH - 1) begin
                if (issued_mask[i])
                    val_map[i+1] = val_map[i] & ~(IQ_SIZE'(1) << winners[i]);
                else
                    val_map[i+1] = 'd0;
            end
        end

        // Insert output and tracking setting
        num_inserts = $countones(inserted_mask);
        inserted = 'd0;
        inserted_entry = 'd0;
        idx_map = 'd0;
        for (int i = 0; i < IQ_SIZE; i++) begin
            ins_map[0][i] = ~entries[i].valid;
        end
        for (int i = 0; i < PPL_WIDTH; i++) begin
            for (int j = 0; j < IQ_SIZE; j++) begin
                if (ins_map[i][j] && i < num_inserts) begin
                    inserted_entry[j] = inserted_entries[i];
                    inserted[j] = 1'b1;
                    idx_map[i] = j;
                    break;
                end
            end

            // Set map for next stage
            if (i < PPL_WIDTH - 1)
                ins_map[i+1] = ins_map[i] & ~(IQ_SIZE'(1) << idx_map[i]);
        end
    end

    // Output mapping
    always_comb begin
        issued = 'd0;
        issued_entries = 'd0;
        for (int i = 0; i < PPL_WIDTH; i++) begin
            if (issued_mask[i]) begin
                issued_entries[i] = entries[winners[i]];
                issued[winners[i]] = 1'b1;
            end
        end
    end

    // Full generation
    logic [IQ_SIZE-1:0] valid_mask;
    logic [IQ_BIT:0] occupied_count;
    always_comb begin
        for (int i = 0; i < IQ_SIZE; i++) begin
            valid_mask[i] = entries[i].valid;
        end
    end
    assign occupied_count = $countones(valid_mask);
    assign full = (occupied_count + PPL_WIDTH > IQ_SIZE);
endmodule: IQ
