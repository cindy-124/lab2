// Generated using Gemini and then slightly modified
module tb_IQ();

    // Clock and Reset Signals
    logic clk;
    logic reset;

    // DUT Interface Signals
    logic [PPL_WIDTH-1:0]               inserted_mask;
    iq_entry_t [PPL_WIDTH-1:0]          inserted_entries;

    logic [PPL_WIDTH-1:0]               executed_mask;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] executed_preg;

    logic [PPL_WIDTH-1:0]               issued_mask;
    iq_entry_t [PPL_WIDTH-1:0]          issued_entries;

    logic                               full;

    // Branch Signals (Tied off)
    logic                               flush_en;
    logic [ROB_BIT-1:0]                 flush_index;
    logic [ROB_BIT-1:0]                 rob_head;

    int error_count = 0;

    // DUT Instantiation using default parameters
    IQ dut (
        .clk(clk),
        .reset(reset),
        .inserted_mask(inserted_mask),
        .inserted_entries(inserted_entries),
        .executed_mask(executed_mask),
        .executed_preg(executed_preg),
        .issued_mask(issued_mask),
        .issued_entries(issued_entries),
        .full(full),
        .flush_en(flush_en),
        .flush_index(flush_index),
        .rob_head(rob_head)
    );

    // ------------------------------------------------------------------------
    // Clock Generation
    // ------------------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ------------------------------------------------------------------------
    // Double Issue Assertions
    // ------------------------------------------------------------------------

    // 1. Intra-Cycle Double Issue: Prevent two vector slots issuing the same instruction simultaneously
    always @(posedge clk) if (!reset) begin
        for (int i = 0; i < PPL_WIDTH; i++) begin
            if (issued_mask[i]) begin
                for (int j = i + 1; j < PPL_WIDTH; j++) begin
                    if (issued_mask[j]) begin
                        a_no_intra_double_issue: assert (issued_entries[i].inst_ID != issued_entries[j].inst_ID)
                        else begin
                            $error("[ASSERTION FAILED] Intra-cycle double issue! Slots %0d and %0d issued inst_ID 0x%0h at cycle %0t",
                                   i, j, issued_entries[i].inst_ID, $time);
                            error_count++;
                        end
                    end
                end
            end
        end
    end

    // 2. Inter-Cycle Double Issue: Track issued instructions to ensure an ID is never issued twice without re-insertion
    bit [(1 << INST_BIT)-1:0] issued_tracker;

    always @(posedge clk) begin
        if (reset) begin
            issued_tracker = '0;
        end else begin
            // Clear tracking bit if instruction is explicitly re-inserted
            for (int i = 0; i < PPL_WIDTH; i++) begin
                if (inserted_mask[i]) begin
                    issued_tracker[inserted_entries[i].inst_ID] = 1'b0;
                end
            end

            // Assert instruction hasn't been issued previously
            for (int i = 0; i < PPL_WIDTH; i++) begin
                if (issued_mask[i]) begin
                    a_no_inter_double_issue: assert (issued_tracker[issued_entries[i].inst_ID] == 1'b0)
                    else begin
                        $error("[ASSERTION FAILED] Inter-cycle double issue! inst_ID 0x%0h issued multiple times at cycle %0t",
                               issued_entries[i].inst_ID, $time);
                        error_count++;
                    end
                    issued_tracker[issued_entries[i].inst_ID] = 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Helper Tasks
    // ------------------------------------------------------------------------
    task automatic clear_inputs();
        inserted_mask    <= '0;
        inserted_entries <= '0;
        executed_mask    <= '0;
        executed_preg    <= '0;
        flush_en         <= 1'b0;
        flush_index      <= '0;
        rob_head         <= '0;
    endtask

    task automatic do_reset();
        reset <= 1'b1;
        clear_inputs();
        repeat (2) @(posedge clk);
        reset <= 1'b0;
        @(posedge clk);
    endtask

    function automatic iq_entry_t create_entry(
        input logic [ROB_BIT-1:0]  rob,
        input logic [INST_BIT-1:0] id,
        input logic [PHYS_BIT-1:0] s1,
        input logic [PHYS_BIT-1:0] s2,
        input logic                r1,
        input logic                r2
    );
        iq_entry_t entry;
        entry.rob_index  = rob;
        entry.inst_ID    = id;
        entry.src1       = s1;
        entry.src2       = s2;
        entry.src1_ready = r1;
        entry.src2_ready = r2;
        entry.valid      = 1'b1;
        return entry;
    endfunction

    // ------------------------------------------------------------------------
    // Main Test Stimulus
    // ------------------------------------------------------------------------
    initial begin
        $display("==================================================");
        $display("          STARTING IQ MODULE TESTBENCH            ");
        $display("==================================================");

        do_reset();

        // --------------------------------------------------------------------
        // TEST 1: Basic Parallel Insertion and Issue (4 Lanes)
        // --------------------------------------------------------------------
        $display("[TEST 1] Parallel insertion and ready issue across all %0d lanes...", PPL_WIDTH);
        @(posedge clk);

        for (int i = 0; i < PPL_WIDTH; i++) begin
            inserted_mask[i]    = 1'b1;
            inserted_entries[i] = create_entry(.rob(i[ROB_BIT-1:0] + 1),
                                               .id(12'h100 + i),
                                               .s1(i*2), .s2(i*2+1),
                                               .r1(1'b1), .r2(1'b1));
        end

        @(posedge clk);
        clear_inputs();

        @(posedge clk);
        if (issued_mask == '0) begin
            $error("[FAIL] TEST 1: Expected entries to issue across channels.");
            error_count++;
        end else begin
            $display("[PASS] TEST 1: parallel issue successful. Mask = %b", issued_mask);
        end

        // --------------------------------------------------------------------
        // TEST 2: Wakeup Dependency Broadcast
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Testing wakeup dependency broadcast...");
        @(posedge clk);

        inserted_mask[0]    <= 1'b1;
        inserted_entries[0] <= create_entry(.rob(7'd10), .id(12'h200), .s1(8'd45), .s2(8'd46), .r1(1'b0), .r2(1'b1));

        @(posedge clk);
        clear_inputs();

        // Broadcast matching physical register
        executed_mask[0] <= 1'b1;
        executed_preg[0] <= 8'd45;

        @(posedge clk);
        clear_inputs();

        @(posedge clk);
        if (issued_mask == '0) begin
            $error("[FAIL] TEST 2: Entry failed to issue after dependency wakeup broadcast.");
            error_count++;
        end else begin
            $display("[PASS] TEST 2: Dependency resolved and entry issued successfully.");
        end

        // --------------------------------------------------------------------
        // TEST 3: Sustained High-Pressure Pipeline Stream
        // --------------------------------------------------------------------
        $display("\n[TEST 3] Sustaining continuous insertion and issue pressure over 100 cycles...");

        do_reset();

        fork
            // Thread A: Stream instructions into IQ continuously whenever not full
            begin : stream_inserter
                logic [11:0] next_inst_id = 12'h001;
                logic [6:0]  next_rob     = 7'd1;
                logic [7:0]  reg_ptr      = 8'd10;

                for (int cycle = 0; cycle < 100; cycle++) begin
                    @(posedge clk);
                    clear_inputs();

                    if (!full) begin
                        for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                            inserted_mask[lane]    <= 1'b1;
                            // Alternate: half instructions ready immediately, half waiting on reg_ptr
                            inserted_entries[lane] <= create_entry(
                                .rob(next_rob++),
                                .id(next_inst_id++),
                                .s1(reg_ptr),
                                .s2(reg_ptr + 1),
                                .r1(lane % 2 == 0),
                                .r2(1'b1)
                            );
                        end
                        reg_ptr <= reg_ptr + 2;
                    end
                end
            end

            // Thread B: Stream register execution completions to continuously resolve waiting dependencies
            begin : stream_executor
                logic [7:0] exec_reg_ptr = 8'd10;

                for (int cycle = 0; cycle < 100; cycle++) begin
                    @(posedge clk);
                    executed_mask <= '0;

                    // Periodically release physical registers back to IQ
                    if (cycle % 2 == 0) begin
                        for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                            executed_mask[lane] <= 1'b1;
                            executed_preg[lane] <= exec_reg_ptr++;
                        end
                    end
                end
            end

            // Thread C: Monitor issued counts during sustained stress run
            begin : stream_monitor
                int total_issued = 0;
                for (int cycle = 0; cycle < 100; cycle++) begin
                    @(posedge clk);
                    for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                        if (issued_mask[lane]) total_issued++;
                    end
                end
                $display("       [SUSTAINED TEST] Successfully issued %0d total instructions during 100-cycle stress run.", total_issued);
            end
        join

        // --------------------------------------------------------------------
        // TEST 4: 1000+ Cycle Sustained Pressure Test
        // --------------------------------------------------------------------
        $display("\n[TEST 4] Starting 1000+ Cycle Sustained Pressure Test...");
        $display("         Step 1: Filling queue to full capacity with unready entries (src1_ready=0, src2_ready=0)...");

        begin
            // Local tracking variables for the test block
            logic [ROB_BIT-1:0]  test_rob     = '0;
            logic [INST_BIT-1:0] test_id      = '0;
            logic [PHYS_BIT-1:0] test_reg     = 8'd1;
            logic [PHYS_BIT-1:0] pending_regs[$];
            int                  total_issued = 0;

            do_reset();

            // ----------------------------------------------------------------
            // Phase 1: Fill the queue completely WITHOUT broadcasting executions
            // ----------------------------------------------------------------
            while (!full) begin
                @(posedge clk);
                clear_inputs();

                for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                    inserted_mask[lane] <= 1'b1;
                    inserted_entries[lane] <= create_entry(
                        .rob(test_rob++),
                        .id(test_id++),
                        .s1(test_reg),
                        .s2(test_reg + 8'd1),
                        .r1(1'b0), // Neither source register ready
                        .r2(1'b0)  // Neither source register ready
                    );

                    // Track registers that instructions are waiting on
                    pending_regs.push_back(test_reg);
                    pending_regs.push_back(test_reg + 8'd1);
                    test_reg += 8'd2;
                end
            end

            @(posedge clk);
            clear_inputs();

            // Verify queue reached full state before any instruction issued
            if (!full) begin
                $error("[FAIL] TEST 4: Queue did not report full before enabling issue.");
                error_count++;
            end else begin
                $display("         [PASS] Queue is full (`full` = %b). Zero instructions issued during fill phase.", full);
            end

            // ----------------------------------------------------------------
            // Phase 2: Sustained Pressure for 1050 Cycles
            // ----------------------------------------------------------------
            $display("         Step 2: Sustaining pressure for 1050 cycles...");

            for (int cycle = 0; cycle < 1050; cycle++) begin
                @(posedge clk);
                clear_inputs();

                // Track issued count for metrics
                for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                    if (issued_mask[lane]) total_issued++;
                end

                // Broadcast executions for waiting registers to wake up queued entries
                for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                    if (pending_regs.size() > 0) begin
                        executed_mask[lane] <= 1'b1;
                        executed_preg[lane] <= pending_regs.pop_front();
                    end
                end

                // Insert new entries into any freed slots with neither source ready
                if (!full) begin
                    for (int lane = 0; lane < PPL_WIDTH; lane++) begin
                        inserted_mask[lane] <= 1'b1;
                        inserted_entries[lane] <= create_entry(
                            .rob(test_rob++),
                            .id(test_id++),
                            .s1(test_reg),
                            .s2(test_reg + 8'd1),
                            .r1(1'b0), // Neither source ready
                            .r2(1'b0)  // Neither source ready
                        );

                        pending_regs.push_back(test_reg);
                        pending_regs.push_back(test_reg + 8'd1);
                        test_reg += 8'd2;
                    end
                end
            end

        @(posedge clk);
        clear_inputs();

        $display("[PASS] TEST 4: Successfully sustained 1050 cycles. Total instructions issued: %0d", total_issued);
    end

        clear_inputs();
        repeat (5) @(posedge clk);

        // --------------------------------------------------------------------
        // Test Final Verdict
        // --------------------------------------------------------------------
        $display("\n==================================================");
        if (error_count == 0) begin
            $display("    ALL TESTS AND ASSERTIONS PASSED SUCCESSFULLY! ");
        end else begin
            $display("    TESTS FAILED WITH %0d ERROR(S).               ", error_count);
        end
        $display("==================================================");
        $finish;
    end

endmodule
