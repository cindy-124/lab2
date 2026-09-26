`default_nettype none

module PRF (

	// Clock and synchronous active high reset
	input  logic clk, reset,
	
	// Incoming entry signals
	input  logic [PPL_WIDTH-1:0] inserted_mask,
	input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] inserted_preg,

	// Executed instruction signals
	input  logic [PPL_WIDTH-1:0] executed_mask,
	input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] executed_preg,
	
	// Committed instruction signals
	input  logic [PPL_WIDTH-1:0] committed_mask,
	input  logic [PPL_WIDTH-1:0] removed_mask,
	input  logic [PPL_WIDTH-1:0][PHYS_BIT-1:0] removed_preg,
	input  logic [PPL_WIDTH-1:0][ARCH_BIT-1:0] removed_areg,
	
	// PRF FSMs
	output logic [PHYS_REG-1:0][1:0] preg_states,

	// ArchRAT
	output logic [ARCH_REG-1:0][PHYS_BIT-1:0] archRAT
);
    
    //empty->reserved //reserved->has answer
    //has answer-> offcial //offcial-> empty
    //reserved/has answer->empty (cancelled)
    //has answer-> empty(supersed)

    localparam logic [1:0] S_AVAIL = 2'b00;
    localparam logic [1:0] S_RNV   = 2'b01;
    localparam logic [1:0] S_RV    = 2'b10;
    localparam logic [1:0] S_ARCH  = 2'b11; //offcially update in the arch
 
    logic [PHYS_REG-1:0][1:0]          next_states;
    logic [ARCH_REG-1:0][PHYS_BIT-1:0] next_archRAT;
 
    always_comb begin
        next_states  = preg_states;
        next_archRAT = archRAT;
 
        //1) Completions: RNV -> RV
        for (int i = 0; i < PPL_WIDTH; i++) begin
            if (executed_mask[i] && preg_states[executed_preg[i]] == S_RNV) //finish exec
                next_states[executed_preg[i]] = S_RV;
        end
 
        //2) ROB removals, oldest (lane 0) to youngest.
        //Processing in order also covers "superseded by a younger instr in the same batch"
        for (int i = 0; i < PPL_WIDTH; i++) begin
            if (removed_mask[i]) begin
                if (committed_mask[i]) begin //offcially leave the ROB(commited)
                    next_states[next_archRAT[removed_areg[i]]] = S_AVAIL; //old mapping dies
                    next_states[removed_preg[i]]               = S_ARCH;
                    next_archRAT[removed_areg[i]]              = removed_preg[i];
                end else begin
                    next_states[removed_preg[i]] = S_AVAIL;              //squashed
                end
            end
        end
 
        //3) New allocations: AVAIL -> RNV.
        //    Safe to apply last: the RRU only picks pregs that are AVAIL
        //    *this* cycle, so none of them can collide with steps 1-2.
        for (int i = 0; i < PPL_WIDTH; i++) begin
            if (inserted_mask[i])
                next_states[inserted_preg[i]] = S_RNV;
        end
    end
 
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int p = 0; p < PHYS_REG; p++)
                preg_states[p] <= (p < ARCH_REG) ? S_ARCH : S_AVAIL;
            for (int a = 0; a < ARCH_REG; a++)
                archRAT[a] <= PHYS_BIT'(a);
        end else begin
            preg_states <= next_states;
            archRAT     <= next_archRAT;
        end
    end
endmodule: PRF
