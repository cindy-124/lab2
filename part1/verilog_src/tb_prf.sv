/*
 * Unit testbench for PRF (Task 4.2)
 *
 * Build & run from part1/:
 *   vcs -sverilog verilog_src/global_defines.svh \
 *       verilog_src/rename_modules/prf.sv verilog_src/tb_prf.sv \
 *       -top TB_PRF -o simv_prf
 *   ./simv_prf
 *
 * Tests:
 *   1. Reset values
 *   2. Full lifecycle: allocate -> execute -> commit, old mapping freed
 *   3. Two commits to the same areg in one batch (superseded path)
 *   4. Squash (removed, not committed), before and after execution
 *   5. Mixed batch: one lane commits, the next is squashed
 *   6. Allocate + execute + commit of different pregs in the same cycle
 *   7. Full-width (PPL_WIDTH lanes) allocate / execute / commit
 *   8. Recycling a freed low-numbered preg
 *   9. Global invariants: exactly ARCH_REG architectural regs,
 *      and every archRAT entry points at an architectural preg
 */
module TB_PRF;

    localparam logic [1:0] AVAIL = 2'b00, RNV = 2'b01, RV = 2'b10, ARCH = 2'b11;

    logic clk, reset;
    logic [PPL_WIDTH-1:0]               inserted_mask, executed_mask, committed_mask, removed_mask;
    logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] inserted_preg, executed_preg, removed_preg;
    logic [PPL_WIDTH-1:0][ARCH_BIT-1:0] removed_areg;
    logic [PHYS_REG-1:0][1:0]           preg_states;
    logic [ARCH_REG-1:0][PHYS_BIT-1:0]  archRAT;

    PRF dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    int errors = 0;

    // ---------------- helpers ----------------
    task automatic clear_inputs();
        inserted_mask  = '0; inserted_preg = '0;
        executed_mask  = '0; executed_preg = '0;
        committed_mask = '0; removed_mask  = '0;
        removed_preg   = '0; removed_areg  = '0;
    endtask

    // Inputs set before calling tick() are sampled on the next rising edge.
    task automatic tick();
        @(posedge clk); #1;
        clear_inputs();
    endtask

    task automatic alloc(input int lane, input int p);
        inserted_mask[lane] = 1'b1;
        inserted_preg[lane] = PHYS_BIT'(p);
    endtask

    task automatic exec(input int lane, input int p);
        executed_mask[lane] = 1'b1;
        executed_preg[lane] = PHYS_BIT'(p);
    endtask

    task automatic remove(input int lane, input int p, input int a, input bit commit);
        removed_mask[lane]   = 1'b1;
        committed_mask[lane] = commit;
        removed_preg[lane]   = PHYS_BIT'(p);
        removed_areg[lane]   = ARCH_BIT'(a);
    endtask

    task automatic expect_state(input int p, input logic [1:0] exp, input string msg);
        if (preg_states[p] !== exp) begin
            $display("FAIL [%s] preg %0d state = %b, expected %b", msg, p, preg_states[p], exp);
            errors++;
        end
    endtask

    task automatic expect_rat(input int a, input int p, input string msg);
        if (archRAT[a] !== PHYS_BIT'(p)) begin
            $display("FAIL [%s] archRAT[%0d] = %0d, expected %0d", msg, a, archRAT[a], p);
            errors++;
        end
    endtask

    // ---------------- tests ----------------
    initial begin
        clear_inputs();
        reset = 1'b1;
        @(posedge clk); @(posedge clk); #1;
        reset = 1'b0;

        // 1. Reset
        for (int p = 0; p < PHYS_REG; p++) expect_state(p, (p < ARCH_REG) ? ARCH : AVAIL, "T1 reset");
        for (int a = 0; a < ARCH_REG; a++) expect_rat(a, a, "T1 reset");

        // 2. Lifecycle: x1 renamed to p32
        alloc(0, 32);                tick();
        expect_state(32, RNV,   "T2 alloc");
        exec(0, 32);                 tick();
        expect_state(32, RV,    "T2 exec");
        remove(0, 32, 1, 1);         tick();
        expect_state(32, ARCH,  "T2 commit: new preg");
        expect_state(1,  AVAIL, "T2 commit: old preg freed");
        expect_rat  (1,  32,    "T2 commit");

        // 3. Same-batch supersede: x2 -> p33 then x2 -> p34, commit together
        alloc(0, 33); alloc(1, 34); tick();
        exec(0, 33);  exec(1, 34);  tick();
        remove(0, 33, 2, 1); remove(1, 34, 2, 1); tick();
        expect_state(33, AVAIL, "T3 older superseded");
        expect_state(34, ARCH,  "T3 younger arch");
        expect_state(2,  AVAIL, "T3 original freed");
        expect_rat  (2,  34,    "T3");

        // 4. Squash: p35 executed, p36 not; both squashed
        alloc(0, 35); alloc(1, 36); tick();
        exec(0, 35);                tick();
        remove(0, 35, 3, 0); remove(1, 36, 4, 0); tick();
        expect_state(35, AVAIL, "T4 squash after exec");
        expect_state(36, AVAIL, "T4 squash before exec");
        expect_state(3,  ARCH,  "T4 arch untouched");
        expect_state(4,  ARCH,  "T4 arch untouched");
        expect_rat  (3,  3,     "T4");
        expect_rat  (4,  4,     "T4");

        // 5. Mixed batch: lane 0 commits x5, lane 1 (x6) squashed
        alloc(0, 37); alloc(1, 38); tick();
        exec(0, 37);  exec(1, 38);  tick();
        remove(0, 37, 5, 1); remove(1, 38, 6, 0); tick();
        expect_state(37, ARCH,  "T5 committed lane");
        expect_state(5,  AVAIL, "T5 old x5 freed");
        expect_rat  (5,  37,    "T5");
        expect_state(38, AVAIL, "T5 squashed lane");
        expect_state(6,  ARCH,  "T5 x6 untouched");
        expect_rat  (6,  6,     "T5");

        // 6. Simultaneous events on different pregs in one cycle
        alloc(0, 40); alloc(1, 41); tick();
        exec(0, 41);                tick();
        alloc(0, 39); exec(0, 40); remove(0, 41, 7, 1); tick();
        expect_state(39, RNV,   "T6 alloc same cycle");
        expect_state(40, RV,    "T6 exec same cycle");
        expect_state(41, ARCH,  "T6 commit same cycle");
        expect_state(7,  AVAIL, "T6 old x7 freed");
        expect_rat  (7,  41,    "T6");

        // 7. Full width: x9..x(8+W) -> p42..
        for (int i = 0; i < PPL_WIDTH; i++) alloc(i, 42 + i);             tick();
        for (int i = 0; i < PPL_WIDTH; i++) exec(i, 42 + i);              tick();
        for (int i = 0; i < PPL_WIDTH; i++) remove(i, 42 + i, 9 + i, 1);  tick();
        for (int i = 0; i < PPL_WIDTH; i++) begin
            expect_state(42 + i, ARCH,  "T7 full width new");
            expect_state(9 + i,  AVAIL, "T7 full width old");
            expect_rat  (9 + i,  42 + i, "T7");
        end

        // 8. Recycle p1 (freed in test 2) for x20
        alloc(0, 1);          tick();
        expect_state(1, RNV,  "T8 realloc");
        exec(0, 1);           tick();
        remove(0, 1, 20, 1);  tick();
        expect_state(1,  ARCH,  "T8 recycled preg arch");
        expect_state(20, AVAIL, "T8 old x20 freed");
        expect_rat  (20, 1,     "T8");

        // 9. Invariants
        begin
            int n_arch = 0;
            for (int p = 0; p < PHYS_REG; p++) if (preg_states[p] == ARCH) n_arch++;
            if (n_arch != ARCH_REG) begin
                $display("FAIL [T9] %0d architectural pregs, expected %0d", n_arch, ARCH_REG);
                errors++;
            end
            for (int a = 0; a < ARCH_REG; a++) expect_state(archRAT[a], ARCH, "T9 archRAT target");
        end

        if (errors == 0) $display("\n*** PRF: ALL TESTS PASSED ***\n");
        else             $display("\n*** PRF: %0d CHECK(S) FAILED ***\n", errors);
        $finish;
    end

endmodule