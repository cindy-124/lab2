/*
 * Unit testbench for RRU (Task 5.2)
 *
 * The testbench stands in for the PRF: it drives preg_states itself and marks
 * a preg RNV after the RRU allocates it. Combinational outputs are checked
 * before each clock edge; the specRAT (dut.specRAT) is checked after it.
 *
 * Build & run from part1/:
 *   vcs -sverilog verilog_src/global_defines.svh verilog_src/rename_modules/rru.sv verilog_src/tb_rru.sv -top TB_RRU -o simv_rru
 *   ./simv_rru
 *
 * Tests:
 *   T0 reset: specRAT identity, not full
 *   T1 full-width batch, no dependencies: lowest free pregs, identity sources, all ready
 *   T2 intra-batch RAW / WAR / WAW (x1 written by lanes 0 and 2, read by 1 and 3)
 *   T3 partial batch (1 lane); readiness from RV vs RNV; masked lanes leave specRAT alone
 *   T4 source broadcast in the same cycle is marked ready
 *   T5 all lanes write the same areg (youngest wins); next batch reads it
 *   T6 empty batch (mask = 0) does not change specRAT
 *   T7 free picker skips non-available pregs; full flag at 3 vs 4 free
 */
module TB_RRU;

    localparam logic [1:0] AVAIL = 2'b00, RNV = 2'b01, RV = 2'b10, ARCH = 2'b11;

    logic clk, reset;
    logic [PPL_WIDTH-1:0]               inserted_mask;
    instruction_t [PPL_WIDTH-1:0]       inserted_entries;
    logic [PPL_WIDTH-1:0]               committed_mask, removed_mask, removed_is_branch;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] removed_preg;
    logic [PPL_WIDTH-1:0][ARCH_BIT-1:0] removed_areg;
    logic [PPL_WIDTH-1:0]               executed_mask;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] executed_preg;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] renamed_preg;
    rob_entry_t [PPL_WIDTH-1:0]         renamed_rob_entries;
    iq_entry_t  [PPL_WIDTH-1:0]         renamed_iq_entries;
    logic [PHYS_REG-1:0][1:0]           preg_states;
    logic [ARCH_REG-1:0][PHYS_BIT-1:0]  archRAT;
    logic [PPL_WIDTH-1:0][ROB_BIT-1:0]  inserted_index;
    logic                               full, stall, flush_en;
    logic [ROB_BIT-1:0]                 flush_index;

    RRU dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int errors  = 0;
    int next_id = 0;
    logic [ARCH_REG-1:0][PHYS_BIT-1:0] snap;
    logic [PHYS_REG-1:0][1:0]          saved_states;

    // ---------------- helpers ----------------
    task automatic check(input logic [31:0] got, input logic [31:0] exp, input string msg);
        if (got !== exp) begin
            $display("FAIL [%s] got %0d, expected %0d", msg, got, exp);
            errors++;
        end
    endtask

    task automatic clear_inputs();
        inserted_mask     = '0; inserted_entries = '0;
        committed_mask    = '0; removed_mask     = '0; removed_is_branch = '0;
        removed_preg      = '0; removed_areg     = '0;
        executed_mask     = '0; executed_preg    = '0;
        flush_en          = 1'b0; flush_index    = '0;
        for (int i = 0; i < PPL_WIDTH; i++) inserted_index[i] = ROB_BIT'(i);
    endtask

    // lane: dest = src1 op src2   (x register numbers)
    task automatic set_inst(input int lane, input int dest, input int s1, input int s2);
        inserted_mask[lane]              = 1'b1;
        inserted_entries[lane].dest      = ARCH_BIT'(dest);
        inserted_entries[lane].src1      = ARCH_BIT'(s1);
        inserted_entries[lane].src2      = ARCH_BIT'(s2);
        inserted_entries[lane].inst_ID   = INST_BIT'(next_id);
        inserted_entries[lane].is_branch = 1'b0;
        next_id++;
    endtask

    // Check one lane's IQ entry: source pregs and ready bits
    task automatic check_src(input int lane, input int p1, input bit r1,
                             input int p2, input bit r2, input string msg);
        check(renamed_iq_entries[lane].src1,       p1, {msg, " src1"});
        check(renamed_iq_entries[lane].src1_ready, r1, {msg, " src1_ready"});
        check(renamed_iq_entries[lane].src2,       p2, {msg, " src2"});
        check(renamed_iq_entries[lane].src2_ready, r2, {msg, " src2_ready"});
    endtask

    // Clock edge; afterwards act like the PRF and mark allocated pregs RNV
    task automatic tick();
        logic [PPL_WIDTH-1:0]               m;
        logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] p;
        #1;
        m = inserted_mask;
        p = renamed_preg;
        @(posedge clk); #1;
        for (int i = 0; i < PPL_WIDTH; i++)
            if (m[i]) preg_states[p[i]] = RNV;
        clear_inputs();
    endtask

    // ---------------- tests ----------------
    initial begin
        clear_inputs();
        for (int p = 0; p < PHYS_REG; p++) preg_states[p] = (p < ARCH_REG) ? ARCH : AVAIL;
        for (int a = 0; a < ARCH_REG; a++) archRAT[a] = PHYS_BIT'(a);
        reset = 1'b1;
        @(posedge clk); @(posedge clk); #1;
        reset = 1'b0;

        // T0: reset
        for (int a = 0; a < ARCH_REG; a++) check(dut.specRAT[a], a, "T0 specRAT identity");
        check(full,  0, "T0 full");
        check(stall, 0, "T0 stall");

        // T1: x1=x2+x3, x4=x5+x6, x7=x8+x9, x10=x11+x12 (no dependencies)
        for (int i = 0; i < PPL_WIDTH; i++) set_inst(i, 1 + 3*i, 2 + 3*i, 3 + 3*i);
        #1;
        for (int i = 0; i < PPL_WIDTH; i++) begin
            check(renamed_preg[i], 32 + i, "T1 dest preg");
            check_src(i, 2 + 3*i, 1, 3 + 3*i, 1, "T1");
            check(renamed_iq_entries[i].rob_index,    i,       "T1 iq rob_index");
            check(renamed_iq_entries[i].valid,        1,       "T1 iq valid");
            check(renamed_rob_entries[i].areg,        1 + 3*i, "T1 rob areg");
            check(renamed_rob_entries[i].preg,        32 + i,  "T1 rob preg");
            check(renamed_rob_entries[i].is_completed, 0,      "T1 rob is_completed");
            check(renamed_rob_entries[i].valid,       1,       "T1 rob valid");
        end
        tick();
        for (int i = 0; i < PPL_WIDTH; i++) check(dut.specRAT[1 + 3*i], 32 + i, "T1 specRAT");
        // now: x1->32, x4->33, x7->34, x10->35 (all RNV)

        // T2: intra-batch dependencies
        set_inst(0, 1, 2, 3);   // x1 = x2 + x3
        set_inst(1, 4, 1, 5);   // x4 = x1 + x5   (RAW on lane 0)
        set_inst(2, 1, 6, 7);   // x1 = x6 + x7   (WAR vs lane 1, WAW vs lane 0; x7 -> p34 not ready)
        set_inst(3, 8, 1, 1);   // x8 = x1 + x1   (must pick lane 2, the youngest older writer)
        #1;
        for (int i = 0; i < PPL_WIDTH; i++) check(renamed_preg[i], 36 + i, "T2 dest preg");
        check_src(0,  2, 1,  3, 1, "T2 lane0");
        check_src(1, 36, 0,  5, 1, "T2 lane1");
        check_src(2,  6, 1, 34, 0, "T2 lane2");
        check_src(3, 38, 0, 38, 0, "T2 lane3");
        tick();
        check(dut.specRAT[1], 38, "T2 specRAT x1 (youngest writer)");
        check(dut.specRAT[4], 37, "T2 specRAT x4");
        check(dut.specRAT[8], 39, "T2 specRAT x8");

        // T3: one-lane batch; p34 has executed (RV), p38 has not (RNV)
        preg_states[34] = RV;
        set_inst(0, 13, 7, 1);  // x13 = x7(p34, ready) + x1(p38, not ready)
        #1;
        check(renamed_preg[0], 40, "T3 dest preg");
        check_src(0, 34, 1, 38, 0, "T3");
        for (int i = 1; i < PPL_WIDTH; i++) begin
            check(renamed_iq_entries[i].valid,  0, "T3 unused lane iq valid");
            check(renamed_rob_entries[i].valid, 0, "T3 unused lane rob valid");
        end
        snap = dut.specRAT;
        tick();
        for (int a = 0; a < ARCH_REG; a++)
            check(dut.specRAT[a], (a == 13) ? 40 : snap[a], "T3 only x13 changes");

        // T4: p38 is broadcast THIS cycle while its state is still RNV
        executed_mask[0] = 1'b1;
        executed_preg[0] = PHYS_BIT'(38);
        set_inst(0, 14, 1, 2);  // x14 = x1(p38, being broadcast) + x2(p2, arch)
        #1;
        check(renamed_preg[0], 41, "T4 dest preg");
        check_src(0, 38, 1, 2, 1, "T4 same-cycle wakeup");
        tick();
        check(dut.specRAT[14], 41, "T4 specRAT x14");

        // T5: every lane writes x20
        for (int i = 0; i < PPL_WIDTH; i++) set_inst(i, 20, 21, 22);
        #1;
        for (int i = 0; i < PPL_WIDTH; i++) begin
            check(renamed_preg[i], 42 + i, "T5 dest preg");
            check_src(i, 21, 1, 22, 1, "T5");
        end
        tick();
        check(dut.specRAT[20], 42 + PPL_WIDTH - 1, "T5 specRAT x20 youngest wins");
        set_inst(0, 23, 20, 20);   // next batch must read the youngest x20
        #1;
        check_src(0, 42 + PPL_WIDTH - 1, 0, 42 + PPL_WIDTH - 1, 0, "T5 next batch reads youngest");
        tick();

        // T6: empty batch with junk entries must not touch specRAT
        snap = dut.specRAT;
        inserted_entries[0].dest = ARCH_BIT'(1);
        inserted_entries[1].dest = ARCH_BIT'(2);
        tick();
        for (int a = 0; a < ARCH_REG; a++) check(dut.specRAT[a], snap[a], "T6 empty batch");

        // T7: free picker and full flag
        saved_states = preg_states;
        for (int p = 0; p < PHYS_REG; p++) preg_states[p] = RNV;
        preg_states[100] = AVAIL;
        preg_states[150] = AVAIL;
        preg_states[200] = AVAIL;
        #1;
        check(full, 1, "T7 full with 3 free");
        check(renamed_preg[0], 100, "T7 pick 0");
        check(renamed_preg[1], 150, "T7 pick 1");
        check(renamed_preg[2], 200, "T7 pick 2");
        preg_states[250] = AVAIL;
        #1;
        check(full, 0, "T7 not full with 4 free");
        check(renamed_preg[3], 250, "T7 pick 3");
        preg_states = saved_states;
        #1;

        if (errors == 0) $display("\n*** RRU: ALL TESTS PASSED ***\n");
        else             $display("\n*** RRU: %0d CHECK(S) FAILED ***\n", errors);
        $finish;
    end

endmodule