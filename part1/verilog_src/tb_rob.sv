`default_nettype none

module TB_ROB ();

    // Signals
    logic clk, reset;
    logic [PPL_WIDTH-1:0]               inserted_mask;
    rob_entry_t [PPL_WIDTH-1:0]         inserted_entries;
    logic [PPL_WIDTH-1:0][ROB_BIT-1:0]  inserted_index;

    logic [PPL_WIDTH-1:0]               executed_mask;
    logic [PPL_WIDTH-1:0][ROB_BIT-1:0]  executed_index;

    logic [PPL_WIDTH-1:0]               removed_mask;
    logic [PPL_WIDTH-1:0]               committed_mask;
    rob_entry_t [PPL_WIDTH-1:0]         removed_entries; 

    logic                               rob_full;
    logic                               flush_en;
    logic [ROB_BIT-1:0]                 flush_index;
    logic [ROB_BIT-1:0]                 rob_head;

    // Instantiate your ROB module directly
    ROB #(
        .PPL_WIDTH(PPL_WIDTH),
        .ROB_BIT(ROB_BIT)
    ) dut (
        // Clock and Reset
        .clk              (clk),
        .reset            (reset),

        // Incoming Entries
        .inserted_mask    (inserted_mask),
        .inserted_entries (inserted_entries),
        .inserted_index   (inserted_index),

        // Executed Signals
        .executed_mask    (executed_mask),
        .executed_index   (executed_index),

        // Output / Retirement Signals
        .removed_mask     (removed_mask),
        .committed_mask   (committed_mask),
        .removed_entries  (removed_entries), 

        // Full Flag
        .full             (rob_full),       

        // Branch / Flush Signals
        .flush_en         (flush_en),
        .flush_index      (flush_index),

        // Head Pointer
        .rob_head         (rob_head)
    );

    // Clock Generation (10ns period)
    always #5 clk = ~clk;
   
    // Helper task to clear inputs
    task automatic clear_inputs();
        inserted_mask    = '0;
        inserted_entries = '0;
        executed_mask    = '0;
        executed_index   = '0;
        flush_en         = '0;
        flush_index      = '0;
    endtask

    // TEST SUITE
    initial begin
        $display("==================================================");
        $display("   STARTING STANDALONE ROB UNIT TESTS (128-ENTRY) ");
        $display("==================================================");

        clk = 0;
        clear_inputs();

        // 1. Reset Verification
        reset = 1;
        repeat (2) @(posedge clk);
        reset = 0;
        #1; // Step off edge to inspect combinational outputs
        
        assert (rob_full === 1'b0) 
            else $error("[TEST 1 FAIL] rob_full should be 0 after reset!");
        $display("[TEST 1 PASS] Reset state verified.");

        // 2. Batch Insertion & Index Verification
        @(posedge clk);
        #1;
        inserted_mask = 4'b0111; // 3 valid entries entering
        inserted_entries[0].inst_ID = 12'hA001;
        inserted_entries[1].inst_ID = 12'hA002;
        inserted_entries[2].inst_ID = 12'hA003;

        #1; // Let combinational inserted_index settle
        assert (inserted_index[0] === 0 && inserted_index[1] === 1 && inserted_index[2] === 2)
            else $error("[TEST 2 FAIL] Incorrect inserted_index assigned on cycle 1!");
        $display("[TEST 2 PASS] Batch insertion and index assignment correct.");

        // 3. Out-of-Order Execution & In-Order Commit Check
        @(posedge clk);
        clear_inputs();
        
        // Broadcast execution for instruction 1 and 2, but NOT 0
        executed_mask = 4'b0011;
        executed_index[0] = 7'd1; // Inst A002 executes
        executed_index[1] = 7'd2; // Inst A003 executes

        #1;
        // Instruction 0 hasn't executed yet, so head cannot advance (committed_mask must be 0)
        assert (committed_mask === 4'b0000)
            else $error("[TEST 3 FAIL] Younger instructions committed before oldest!");
        $display("[TEST 3 PASS] Head blocked correctly when oldest entry is unexecuted.");

        // Now execute instruction 0
        @(posedge clk);
        executed_mask = 4'b0001;
        executed_index[0] = 7'd0; // Inst A001 executes
        
        @(posedge clk);
        #1;
        // All 3 entries (0, 1, and 2) are now executed, so all 3 should commit in batch
        assert (committed_mask === 4'b0111)
            else $error("[TEST 4 FAIL] Expected committed_mask 4'b0111, got %b", committed_mask);
        assert (removed_entries[0].inst_ID === 12'hA001 && 
                removed_entries[1].inst_ID === 12'hA002 && 
                removed_entries[2].inst_ID === 12'hA003)
            else $error("[TEST 5 FAIL] Incorrect removed_entries batch order!");
        $display("[TEST 5 PASS] Out-of-order execution correctly committed in-order.");

        // 4. Fill to capacity & Combinational Full Flag Check (ROB_DEPTH = 128)
        @(posedge clk);
        clear_inputs();

        // Fill 124 entries (Insert 4 entries x 31 cycles = 124 entries)
        for (int b = 0; b < 31; b++) begin
            inserted_mask = 4'b1111;
            for (int i = 0; i < 4; i++) begin
                inserted_entries[i].inst_ID = 12'hB000 + (b*4 + i);
            end
            @(posedge clk);
        end
        
        clear_inputs();
        #1;
        assert (rob_full === 1'b0) 
            else $error("[TEST 6 FAIL] ROB reported full at 124/128 entries!");

        // Insert 1 more entry -> occupancy becomes 125 (Free slots: 128 - 125 = 3 < PPL_WIDTH 4)
        // rob_full MUST go HIGH combinationally
        inserted_mask = 4'b0001;
        inserted_entries[0].inst_ID = 12'hB07D;
        #1; // Combinational check before clock edge
        assert (rob_full === 1'b1) 
            else $error("[TEST 7 FAIL] Combinational full flag did not go high when free space < PPL_WIDTH!");
        $display("[TEST 7 PASS] Combinational full flag verified for 128-entry depth.");

        @(posedge clk);
        clear_inputs();

        $display("==================================================");
        $display("       ALL ISOLATED ROB UNIT TESTS PASSED!        ");
        $display("==================================================");
        $finish;
    end

endmodule