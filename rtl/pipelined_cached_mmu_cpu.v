`timescale 1ns/1ps

module pipelined_cached_mmu_cpu #(
    parameter IMEM_WORDS = 512,
    parameter DMEM_BYTES = 2048,
    parameter MEMFILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    output reg  [31:0] debug_pc,
    output reg  [31:0] debug_cycle,
    output reg  [31:0] debug_instret,
    output reg  [31:0] debug_icache_hits,
    output reg  [31:0] debug_icache_misses,
    output reg  [31:0] debug_dcache_hits,
    output reg  [31:0] debug_dcache_misses,
    output reg  [31:0] debug_mmu_hits,
    output reg  [31:0] debug_mmu_faults,
    output reg         debug_flush,
    output reg         debug_stall,
    output reg         halted
);
    integer i;

    localparam OP_R      = 7'b0110011;
    localparam OP_I      = 7'b0010011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;

    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [7:0]  dmem [0:DMEM_BYTES-1];
    reg [31:0] regs [0:31];

    reg        ic_valid [0:7];
    reg [26:0] ic_tag [0:7];
    reg        dc_valid [0:7];
    reg [26:0] dc_tag [0:7];

    reg        tlb_valid [0:3];
    reg [19:0] tlb_vpn [0:3];
    reg [19:0] tlb_ppn [0:3];
    reg [2:0]  tlb_perm [0:3]; // R W X

    reg [31:0] pc;
    reg [2:0]  halt_drain;

    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instr;

    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_instr;
    reg [31:0] id_ex_rs1_val;
    reg [31:0] id_ex_rs2_val;
    reg [31:0] id_ex_imm_i;
    reg [31:0] id_ex_imm_s;
    reg [31:0] id_ex_imm_b;
    reg [31:0] id_ex_imm_u;
    reg [31:0] id_ex_imm_j;
    reg [4:0]  id_ex_rs1;
    reg [4:0]  id_ex_rs2;
    reg [4:0]  id_ex_rd;
    reg [2:0]  id_ex_funct3;
    reg [6:0]  id_ex_funct7;
    reg [6:0]  id_ex_opcode;

    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_instr;
    reg [31:0] ex_mem_alu;
    reg [31:0] ex_mem_rs2_val;
    reg [4:0]  ex_mem_rd;
    reg [2:0]  ex_mem_funct3;
    reg        ex_mem_reg_write;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;
    reg        ex_mem_wb_mem;

    reg        mem_wb_valid;
    reg [31:0] mem_wb_pc;
    reg [31:0] mem_wb_instr;
    reg [31:0] mem_wb_data;
    reg [4:0]  mem_wb_rd;
    reg        mem_wb_reg_write;

    wire [6:0] id_opcode = if_id_instr[6:0];
    wire [4:0] id_rd = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];
    wire [4:0] id_rs1 = if_id_instr[19:15];
    wire [4:0] id_rs2 = if_id_instr[24:20];
    wire [6:0] id_funct7 = if_id_instr[31:25];
    wire [31:0] id_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] id_imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] id_imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7], if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] id_imm_u = {if_id_instr[31:12], 12'h000};
    wire [31:0] id_imm_j = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12], if_id_instr[20], if_id_instr[30:21], 1'b0};

    wire load_use_hazard = id_ex_valid && id_ex_opcode == OP_LOAD && id_ex_rd != 5'd0 &&
                           if_id_valid && (id_ex_rd == id_rs1 || id_ex_rd == id_rs2);

    wire [31:0] rs1_file = (id_rs1 == 5'd0) ? 32'h00000000 : regs[id_rs1];
    wire [31:0] rs2_file = (id_rs2 == 5'd0) ? 32'h00000000 : regs[id_rs2];

    wire [31:0] fwd_rs1_a = (ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs1) ? ex_mem_alu :
                            (mem_wb_valid && mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs1) ? mem_wb_data :
                            id_ex_rs1_val;
    wire [31:0] fwd_rs2_a = (ex_mem_valid && ex_mem_reg_write && !ex_mem_mem_read && ex_mem_rd != 5'd0 && ex_mem_rd == id_ex_rs2) ? ex_mem_alu :
                            (mem_wb_valid && mem_wb_reg_write && mem_wb_rd != 5'd0 && mem_wb_rd == id_ex_rs2) ? mem_wb_data :
                            id_ex_rs2_val;

    reg [31:0] ex_alu;
    reg [31:0] ex_next_pc;
    reg        ex_take_branch;
    reg        ex_reg_write;
    reg        ex_mem_read;
    reg        ex_mem_write;
    reg        ex_wb_mem;

    function [33:0] translate;
        input [31:0] vaddr;
        input want_r;
        input want_w;
        input want_x;
        integer t;
        reg found;
        reg fault;
        reg [31:0] pa;
        begin
            found = 1'b0;
            fault = 1'b1;
            pa = 32'h00000000;
            for (t = 0; t < 4; t = t + 1) begin
                if (!found && tlb_valid[t] && vaddr[31:12] == tlb_vpn[t]) begin
                    found = 1'b1;
                    pa = {tlb_ppn[t], vaddr[11:0]};
                    fault = (want_r && !tlb_perm[t][0]) || (want_w && !tlb_perm[t][1]) || (want_x && !tlb_perm[t][2]);
                end
            end
            translate = {fault, found, pa};
        end
    endfunction

    function [31:0] load_word;
        input [31:0] addr;
        begin
            load_word = {dmem[addr + 3], dmem[addr + 2], dmem[addr + 1], dmem[addr]};
        end
    endfunction

    task store_word;
        input [31:0] addr;
        input [31:0] value;
        begin
            dmem[addr] <= value[7:0];
            dmem[addr + 1] <= value[15:8];
            dmem[addr + 2] <= value[23:16];
            dmem[addr + 3] <= value[31:24];
        end
    endtask

    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) imem[i] = 32'h00000013;
        for (i = 0; i < DMEM_BYTES; i = i + 1) dmem[i] = 8'h00;
        if (MEMFILE != "") $readmemh(MEMFILE, imem);
    end

    always @(*) begin
        ex_alu = 32'h00000000;
        ex_next_pc = id_ex_pc + 32'd4;
        ex_take_branch = 1'b0;
        ex_reg_write = 1'b0;
        ex_mem_read = 1'b0;
        ex_mem_write = 1'b0;
        ex_wb_mem = 1'b0;

        case (id_ex_opcode)
            OP_R: begin
                ex_reg_write = 1'b1;
                case ({id_ex_funct7, id_ex_funct3})
                    {7'b0000000, 3'b000}: ex_alu = fwd_rs1_a + fwd_rs2_a;
                    {7'b0100000, 3'b000}: ex_alu = fwd_rs1_a - fwd_rs2_a;
                    {7'b0000000, 3'b111}: ex_alu = fwd_rs1_a & fwd_rs2_a;
                    {7'b0000000, 3'b110}: ex_alu = fwd_rs1_a | fwd_rs2_a;
                    {7'b0000000, 3'b100}: ex_alu = fwd_rs1_a ^ fwd_rs2_a;
                    default: ex_alu = 32'hbad00001;
                endcase
            end
            OP_I: begin
                ex_reg_write = 1'b1;
                case (id_ex_funct3)
                    3'b000: ex_alu = fwd_rs1_a + id_ex_imm_i;
                    3'b111: ex_alu = fwd_rs1_a & id_ex_imm_i;
                    3'b110: ex_alu = fwd_rs1_a | id_ex_imm_i;
                    3'b100: ex_alu = fwd_rs1_a ^ id_ex_imm_i;
                    default: ex_alu = 32'hbad00002;
                endcase
            end
            OP_LOAD: begin
                ex_alu = fwd_rs1_a + id_ex_imm_i;
                ex_reg_write = 1'b1;
                ex_mem_read = 1'b1;
                ex_wb_mem = 1'b1;
            end
            OP_STORE: begin
                ex_alu = fwd_rs1_a + id_ex_imm_s;
                ex_mem_write = 1'b1;
            end
            OP_BRANCH: begin
                case (id_ex_funct3)
                    3'b000: ex_take_branch = (fwd_rs1_a == fwd_rs2_a);
                    3'b001: ex_take_branch = (fwd_rs1_a != fwd_rs2_a);
                    default: ex_take_branch = 1'b0;
                endcase
                ex_next_pc = ex_take_branch ? id_ex_pc + id_ex_imm_b : id_ex_pc + 32'd4;
            end
            OP_JAL: begin
                ex_reg_write = 1'b1;
                ex_alu = id_ex_pc + 32'd4;
                ex_next_pc = id_ex_pc + id_ex_imm_j;
                ex_take_branch = 1'b1;
            end
            OP_JALR: begin
                ex_reg_write = 1'b1;
                ex_alu = id_ex_pc + 32'd4;
                ex_next_pc = (fwd_rs1_a + id_ex_imm_i) & 32'hfffffffe;
                ex_take_branch = 1'b1;
            end
            OP_LUI: begin
                ex_reg_write = 1'b1;
                ex_alu = id_ex_imm_u;
            end
            OP_AUIPC: begin
                ex_reg_write = 1'b1;
                ex_alu = id_ex_pc + id_ex_imm_u;
            end
            default: begin
                ex_alu = 32'hbad000ff;
            end
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'h00000000;
            debug_pc <= 32'h00000000;
            debug_cycle <= 32'h00000000;
            debug_instret <= 32'h00000000;
            debug_icache_hits <= 32'h00000000;
            debug_icache_misses <= 32'h00000000;
            debug_dcache_hits <= 32'h00000000;
            debug_dcache_misses <= 32'h00000000;
            debug_mmu_hits <= 32'h00000000;
            debug_mmu_faults <= 32'h00000000;
            debug_flush <= 1'b0;
            debug_stall <= 1'b0;
            halted <= 1'b0;
            halt_drain <= 3'd0;
            if_id_valid <= 1'b0;
            id_ex_valid <= 1'b0;
            ex_mem_valid <= 1'b0;
            mem_wb_valid <= 1'b0;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'h00000000;
            for (i = 0; i < 8; i = i + 1) begin
                ic_valid[i] <= 1'b0;
                ic_tag[i] <= 27'h0;
                dc_valid[i] <= 1'b0;
                dc_tag[i] <= 27'h0;
            end
            for (i = 0; i < 4; i = i + 1) begin
                tlb_valid[i] <= 1'b0;
                tlb_vpn[i] <= 20'h0;
                tlb_ppn[i] <= 20'h0;
                tlb_perm[i] <= 3'b000;
            end
            tlb_valid[0] <= 1'b1; tlb_vpn[0] <= 20'h00000; tlb_ppn[0] <= 20'h00000; tlb_perm[0] <= 3'b111;
        end else if (!halted) begin
            reg [33:0] if_tr;
            reg [33:0] mem_tr;
            reg [31:0] if_pa;
            reg [31:0] mem_pa;
            reg [2:0] if_idx;
            reg [2:0] mem_idx;
            reg [26:0] if_tag;
            reg [26:0] mem_tag;

            debug_cycle <= debug_cycle + 32'd1;
            debug_flush <= 1'b0;
            debug_stall <= load_use_hazard;
            regs[0] <= 32'h00000000;

            if (halt_drain != 3'd0) begin
                halt_drain <= halt_drain - 3'd1;
                if (halt_drain == 3'd1) begin
                    halted <= 1'b1;
                end
            end

            if (mem_wb_valid && mem_wb_reg_write && mem_wb_rd != 5'd0) begin
                regs[mem_wb_rd] <= mem_wb_data;
            end

            if (mem_wb_valid && mem_wb_instr != 32'h00000013) begin
                debug_instret <= debug_instret + 32'd1;
            end

            if (ex_mem_valid && ex_mem_instr == 32'h0000006f && ex_mem_pc == ex_mem_alu - 32'd4 && ex_mem_rd == 5'd0) begin
                halted <= 1'b1;
            end

            mem_wb_valid <= ex_mem_valid;
            mem_wb_pc <= ex_mem_pc;
            mem_wb_instr <= ex_mem_instr;
            mem_wb_rd <= ex_mem_rd;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_data <= ex_mem_alu;
            if (ex_mem_valid && (ex_mem_mem_read || ex_mem_mem_write)) begin
                mem_tr = translate(ex_mem_alu, ex_mem_mem_read, ex_mem_mem_write, 1'b0);
                mem_pa = mem_tr[31:0];
                if (mem_tr[33]) begin
                    debug_mmu_faults <= debug_mmu_faults + 32'd1;
                    mem_wb_reg_write <= 1'b0;
                end else begin
                    debug_mmu_hits <= debug_mmu_hits + 32'd1;
                    mem_idx = mem_pa[4:2];
                    mem_tag = mem_pa[31:5];
                    if (dc_valid[mem_idx] && dc_tag[mem_idx] == mem_tag) debug_dcache_hits <= debug_dcache_hits + 32'd1;
                    else begin
                        debug_dcache_misses <= debug_dcache_misses + 32'd1;
                        dc_valid[mem_idx] <= 1'b1;
                        dc_tag[mem_idx] <= mem_tag;
                    end
                    if (ex_mem_mem_read) begin
                        mem_wb_data <= load_word(mem_pa);
                    end
                    if (ex_mem_mem_write) begin
                        store_word(mem_pa, ex_mem_rs2_val);
                    end
                end
            end

            if (id_ex_valid && ex_take_branch) begin
                if (id_ex_opcode == OP_JAL && id_ex_rd == 5'd0 && ex_next_pc == id_ex_pc && halt_drain == 3'd0) begin
                    halt_drain <= 3'd4;
                end
                pc <= ex_next_pc;
                if_id_valid <= 1'b0;
                id_ex_valid <= 1'b0;
                debug_flush <= 1'b1;
            end else if (!load_use_hazard) begin
                ex_mem_valid <= id_ex_valid;
                ex_mem_pc <= id_ex_pc;
                ex_mem_instr <= id_ex_instr;
                ex_mem_alu <= ex_alu;
                ex_mem_rs2_val <= fwd_rs2_a;
                ex_mem_rd <= id_ex_rd;
                ex_mem_funct3 <= id_ex_funct3;
                ex_mem_reg_write <= ex_reg_write;
                ex_mem_mem_read <= ex_mem_read;
                ex_mem_mem_write <= ex_mem_write;
                ex_mem_wb_mem <= ex_wb_mem;

                id_ex_valid <= if_id_valid;
                id_ex_pc <= if_id_pc;
                id_ex_instr <= if_id_instr;
                id_ex_rs1_val <= rs1_file;
                id_ex_rs2_val <= rs2_file;
                id_ex_imm_i <= id_imm_i;
                id_ex_imm_s <= id_imm_s;
                id_ex_imm_b <= id_imm_b;
                id_ex_imm_u <= id_imm_u;
                id_ex_imm_j <= id_imm_j;
                id_ex_rs1 <= id_rs1;
                id_ex_rs2 <= id_rs2;
                id_ex_rd <= id_rd;
                id_ex_funct3 <= id_funct3;
                id_ex_funct7 <= id_funct7;
                id_ex_opcode <= id_opcode;

                if_tr = translate(pc, 1'b0, 1'b0, 1'b1);
                if_pa = if_tr[31:0];
                if (if_tr[33]) begin
                    debug_mmu_faults <= debug_mmu_faults + 32'd1;
                    if_id_valid <= 1'b0;
                    halted <= 1'b1;
                end else begin
                    debug_mmu_hits <= debug_mmu_hits + 32'd1;
                    if_idx = if_pa[4:2];
                    if_tag = if_pa[31:5];
                    if (ic_valid[if_idx] && ic_tag[if_idx] == if_tag) debug_icache_hits <= debug_icache_hits + 32'd1;
                    else begin
                        debug_icache_misses <= debug_icache_misses + 32'd1;
                        ic_valid[if_idx] <= 1'b1;
                        ic_tag[if_idx] <= if_tag;
                    end
                    if_id_valid <= 1'b1;
                    if_id_pc <= pc;
                    if_id_instr <= imem[if_pa[31:2]];
                    pc <= pc + 32'd4;
                    debug_pc <= pc;
                end
            end else begin
                ex_mem_valid <= 1'b0;
            end
        end
    end
endmodule
