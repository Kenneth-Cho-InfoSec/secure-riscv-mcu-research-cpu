`timescale 1ns/1ps

module secure_riscv_mcu #(
    parameter IMEM_WORDS = 256,
    parameter DMEM_BYTES = 1024,
    parameter MEMFILE = ""
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        timer_irq,
    input  wire        software_irq,
    input  wire        external_irq,
    output reg  [31:0] pc,
    output reg  [31:0] instr,
    output reg  [2:0]  debug_state,
    output reg  [1:0]  debug_priv,
    output reg  [31:0] debug_trap_cause,
    output reg         debug_pmp_deny,
    output reg         debug_csr_write,
    output reg         debug_bus_valid,
    output reg         debug_bus_write,
    output reg  [31:0] debug_bus_addr
);
    localparam ST_FETCH  = 3'd0;
    localparam ST_DECODE = 3'd1;
    localparam ST_EXEC   = 3'd2;
    localparam ST_MEM    = 3'd3;
    localparam ST_WB     = 3'd4;
    localparam ST_TRAP   = 3'd5;

    localparam PRIV_U = 2'd0;
    localparam PRIV_M = 2'd3;

    localparam CAUSE_INSTR_FAULT = 32'd1;
    localparam CAUSE_ILLEGAL     = 32'd2;
    localparam CAUSE_LOAD_FAULT  = 32'd5;
    localparam CAUSE_STORE_FAULT = 32'd7;
    localparam CAUSE_ECALL_U     = 32'd8;
    localparam CAUSE_ECALL_M     = 32'd11;
    localparam CAUSE_TIMER_IRQ   = 32'h80000007;
    localparam CAUSE_SOFT_IRQ    = 32'h80000003;
    localparam CAUSE_EXT_IRQ     = 32'h8000000b;

    localparam CSR_MSTATUS  = 12'h300;
    localparam CSR_MISA     = 12'h301;
    localparam CSR_MIE      = 12'h304;
    localparam CSR_MTVEC    = 12'h305;
    localparam CSR_MSCRATCH = 12'h340;
    localparam CSR_MEPC     = 12'h341;
    localparam CSR_MCAUSE   = 12'h342;
    localparam CSR_MTVAL    = 12'h343;
    localparam CSR_MIP      = 12'h344;
    localparam CSR_MCYCLE   = 12'hB00;
    localparam CSR_MINSTRET = 12'hB02;
    localparam CSR_MHARTID  = 12'hF14;

    localparam CSR_PMPCFG0   = 12'h3A0;
    localparam CSR_PMPBASE0  = 12'h7C0;
    localparam CSR_PMPLIMIT0 = 12'h7D0;

    integer i;

    reg [31:0] imem [0:IMEM_WORDS-1];
    reg [7:0]  dmem [0:DMEM_BYTES-1];
    reg [31:0] regs [0:31];

    reg [31:0] pmp_base [0:7];
    reg [31:0] pmp_limit [0:7];
    reg [7:0]  pmp_cfg [0:7];

    reg [31:0] mstatus;
    reg [31:0] mtvec;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mie;
    reg [31:0] mip;
    reg [31:0] mscratch;
    reg [31:0] mcycle;
    reg [31:0] minstret;

    reg [1:0]  priv;
    reg [31:0] instr_pc;
    reg [31:0] mem_addr;
    reg [31:0] mem_wdata;
    reg [2:0]  mem_funct3;
    reg        mem_is_load;
    reg [4:0]  wb_rd;
    reg [31:0] wb_data;
    reg        wb_en;
    reg [31:0] next_pc;
    reg [31:0] pending_cause;
    reg [31:0] pending_tval;
    reg [31:0] pending_mepc;

    wire [6:0] opcode = instr[6:0];
    wire [4:0] rd = instr[11:7];
    wire [2:0] funct3 = instr[14:12];
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    wire [6:0] funct7 = instr[31:25];
    wire [11:0] csr_addr = instr[31:20];

    wire [31:0] rs1_val = (rs1 == 5'd0) ? 32'h00000000 : regs[rs1];
    wire [31:0] rs2_val = (rs2 == 5'd0) ? 32'h00000000 : regs[rs2];
    wire signed [31:0] s_rs1_val = rs1_val;
    wire signed [31:0] s_rs2_val = rs2_val;

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'h000};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    wire timer_pending = timer_irq;
    wire soft_pending = software_irq;
    wire ext_pending = external_irq;
    wire global_mie = mstatus[3];
    wire take_timer_irq = global_mie && mie[7] && timer_pending;
    wire take_soft_irq = global_mie && mie[3] && soft_pending;
    wire take_ext_irq = global_mie && mie[11] && ext_pending;

    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) begin
            imem[i] = 32'h00000013;
        end
        for (i = 0; i < DMEM_BYTES; i = i + 1) begin
            dmem[i] = 8'h00;
        end
        if (MEMFILE != "") begin
            $readmemh(MEMFILE, imem);
        end
    end

    function [31:0] load_data;
        input [31:0] addr;
        input [2:0] kind;
        begin
            case (kind)
                3'b000: load_data = {{24{dmem[addr][7]}}, dmem[addr]};
                3'b001: load_data = {{16{dmem[addr + 1][7]}}, dmem[addr + 1], dmem[addr]};
                3'b010: load_data = {dmem[addr + 3], dmem[addr + 2], dmem[addr + 1], dmem[addr]};
                3'b100: load_data = {24'h000000, dmem[addr]};
                3'b101: load_data = {16'h0000, dmem[addr + 1], dmem[addr]};
                default: load_data = 32'h00000000;
            endcase
        end
    endfunction

    function pmp_allow;
        input [31:0] addr;
        input        want_r;
        input        want_w;
        input        want_x;
        integer j;
        reg matched;
        reg allow;
        begin
            matched = 1'b0;
            allow = (priv == PRIV_M);
            for (j = 7; j >= 0; j = j - 1) begin
                if (!matched && addr >= pmp_base[j] && addr < pmp_limit[j]) begin
                    matched = 1'b1;
                    allow = 1'b1;
                    if (priv == PRIV_U && !pmp_cfg[j][3]) allow = 1'b0;
                    if (want_r && !pmp_cfg[j][0]) allow = 1'b0;
                    if (want_w && !pmp_cfg[j][1]) allow = 1'b0;
                    if (want_x && !pmp_cfg[j][2]) allow = 1'b0;
                end
            end
            pmp_allow = allow;
        end
    endfunction

    function [31:0] csr_read;
        input [11:0] addr;
        integer k;
        begin
            case (addr)
                CSR_MSTATUS:  csr_read = mstatus;
                CSR_MISA:     csr_read = 32'h40000100; // RV32I
                CSR_MIE:      csr_read = mie;
                CSR_MTVEC:    csr_read = mtvec;
                CSR_MSCRATCH: csr_read = mscratch;
                CSR_MEPC:     csr_read = mepc;
                CSR_MCAUSE:   csr_read = mcause;
                CSR_MTVAL:    csr_read = mtval;
                CSR_MIP:      csr_read = mip;
                CSR_MCYCLE:   csr_read = mcycle;
                CSR_MINSTRET: csr_read = minstret;
                CSR_MHARTID:  csr_read = 32'h00000000;
                CSR_PMPCFG0:  csr_read = {pmp_cfg[3], pmp_cfg[2], pmp_cfg[1], pmp_cfg[0]};
                default: begin
                    csr_read = 32'h00000000;
                    for (k = 0; k < 8; k = k + 1) begin
                        if (addr == CSR_PMPBASE0 + k[11:0]) csr_read = pmp_base[k];
                        if (addr == CSR_PMPLIMIT0 + k[11:0]) csr_read = pmp_limit[k];
                    end
                end
            endcase
        end
    endfunction

    task enter_trap;
        input [31:0] cause;
        input [31:0] tval;
        input [31:0] epc;
        begin
            pending_cause <= cause;
            pending_tval <= tval;
            pending_mepc <= epc;
            debug_trap_cause <= cause;
            debug_pmp_deny <= (cause == CAUSE_INSTR_FAULT || cause == CAUSE_LOAD_FAULT || cause == CAUSE_STORE_FAULT);
            debug_state <= ST_TRAP;
        end
    endtask

    task commit_no_wb;
        input [31:0] pc_value;
        begin
            pc <= pc_value;
            minstret <= minstret + 32'd1;
            debug_state <= ST_FETCH;
        end
    endtask

    task csr_write;
        input [11:0] addr;
        input [31:0] value;
        integer k;
        reg wrote_pmp;
        begin
            debug_csr_write <= 1'b1;
            wrote_pmp = 1'b0;
            case (addr)
                CSR_MSTATUS:  mstatus <= value & 32'h00001888;
                CSR_MIE:      mie <= value & 32'h00000888;
                CSR_MTVEC:    mtvec <= value & 32'hfffffffc;
                CSR_MSCRATCH: mscratch <= value;
                CSR_MEPC:     mepc <= value & 32'hfffffffc;
                CSR_MCAUSE:   mcause <= value;
                CSR_MTVAL:    mtval <= value;
                CSR_PMPCFG0: begin
                    if (!pmp_cfg[0][7]) pmp_cfg[0] <= value[7:0];
                    if (!pmp_cfg[1][7]) pmp_cfg[1] <= value[15:8];
                    if (!pmp_cfg[2][7]) pmp_cfg[2] <= value[23:16];
                    if (!pmp_cfg[3][7]) pmp_cfg[3] <= value[31:24];
                end
                default: begin
                    for (k = 0; k < 8; k = k + 1) begin
                        if (addr == CSR_PMPBASE0 + k[11:0]) begin
                            wrote_pmp = 1'b1;
                            if (!pmp_cfg[k][7]) pmp_base[k] <= value;
                        end
                        if (addr == CSR_PMPLIMIT0 + k[11:0]) begin
                            wrote_pmp = 1'b1;
                            if (!pmp_cfg[k][7]) pmp_limit[k] <= value;
                        end
                    end
                end
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            pc <= 32'h00000000;
            instr <= 32'h00000013;
            instr_pc <= 32'h00000000;
            priv <= PRIV_M;
            debug_state <= ST_FETCH;
            debug_priv <= PRIV_M;
            debug_trap_cause <= 32'h00000000;
            debug_pmp_deny <= 1'b0;
            debug_csr_write <= 1'b0;
            debug_bus_valid <= 1'b0;
            debug_bus_write <= 1'b0;
            debug_bus_addr <= 32'h00000000;
            mstatus <= 32'h00000000;
            mtvec <= 32'h00000040;
            mepc <= 32'h00000000;
            mcause <= 32'h00000000;
            mtval <= 32'h00000000;
            mie <= 32'h00000000;
            mip <= 32'h00000000;
            mscratch <= 32'h00000000;
            mcycle <= 32'h00000000;
            minstret <= 32'h00000000;
            wb_en <= 1'b0;
            wb_rd <= 5'd0;
            wb_data <= 32'h00000000;
            next_pc <= 32'h00000000;
            mem_addr <= 32'h00000000;
            mem_wdata <= 32'h00000000;
            mem_funct3 <= 3'b010;
            mem_is_load <= 1'b0;
            pending_cause <= 32'h00000000;
            pending_tval <= 32'h00000000;
            pending_mepc <= 32'h00000000;
            for (i = 0; i < 32; i = i + 1) regs[i] <= 32'h00000000;
            for (i = 0; i < 8; i = i + 1) begin
                pmp_base[i] <= 32'hffffffff;
                pmp_limit[i] <= 32'h00000000;
                pmp_cfg[i] <= 8'h00;
            end
            pmp_base[0] <= 32'h00000000; pmp_limit[0] <= 32'h00000100; pmp_cfg[0] <= 8'h85; // M boot/trap RX locked
            pmp_base[1] <= 32'h00000100; pmp_limit[1] <= 32'h00000180; pmp_cfg[1] <= 8'h8d; // U user text RX locked
            pmp_base[2] <= 32'h00000200; pmp_limit[2] <= 32'h00000300; pmp_cfg[2] <= 8'h8b; // U user data RW locked
            pmp_base[3] <= 32'h00000300; pmp_limit[3] <= 32'h00000380; pmp_cfg[3] <= 8'h83; // M result data RW locked
        end else begin
            mcycle <= mcycle + 32'd1;
            mip <= {20'h00000, ext_pending, 3'b000, timer_pending, 3'b000, soft_pending, 3'b000};
            regs[0] <= 32'h00000000;
            debug_priv <= priv;
            debug_csr_write <= 1'b0;
            debug_bus_valid <= 1'b0;
            debug_bus_write <= 1'b0;
            debug_pmp_deny <= 1'b0;

            case (debug_state)
                ST_FETCH: begin
                    if (take_timer_irq) begin
                        enter_trap(CAUSE_TIMER_IRQ, 32'h00000000, pc);
                    end else if (take_ext_irq) begin
                        enter_trap(CAUSE_EXT_IRQ, 32'h00000000, pc);
                    end else if (take_soft_irq) begin
                        enter_trap(CAUSE_SOFT_IRQ, 32'h00000000, pc);
                    end else begin
                        debug_bus_valid <= 1'b1;
                        debug_bus_write <= 1'b0;
                        debug_bus_addr <= pc;
                        if (!pmp_allow(pc, 1'b0, 1'b0, 1'b1) || pc[1:0] != 2'b00) begin
                            enter_trap(CAUSE_INSTR_FAULT, pc, pc);
                        end else begin
                            instr <= imem[pc[31:2]];
                            instr_pc <= pc;
                            debug_state <= ST_DECODE;
                        end
                    end
                end

                ST_DECODE: begin
                    debug_state <= ST_EXEC;
                end

                ST_EXEC: begin
                    wb_en <= 1'b0;
                    wb_rd <= rd;
                    next_pc <= instr_pc + 32'd4;
                    case (opcode)
                        7'b0110011: begin
                            wb_en <= 1'b1;
                            case ({funct7, funct3})
                                {7'b0000000, 3'b000}: wb_data <= rs1_val + rs2_val;
                                {7'b0100000, 3'b000}: wb_data <= rs1_val - rs2_val;
                                {7'b0000000, 3'b001}: wb_data <= rs1_val << rs2_val[4:0];
                                {7'b0000000, 3'b010}: wb_data <= (s_rs1_val < s_rs2_val) ? 32'd1 : 32'd0;
                                {7'b0000000, 3'b011}: wb_data <= (rs1_val < rs2_val) ? 32'd1 : 32'd0;
                                {7'b0000000, 3'b100}: wb_data <= rs1_val ^ rs2_val;
                                {7'b0000000, 3'b101}: wb_data <= rs1_val >> rs2_val[4:0];
                                {7'b0100000, 3'b101}: wb_data <= $signed(rs1_val) >>> rs2_val[4:0];
                                {7'b0000000, 3'b110}: wb_data <= rs1_val | rs2_val;
                                {7'b0000000, 3'b111}: wb_data <= rs1_val & rs2_val;
                                default: begin wb_en <= 1'b0; enter_trap(CAUSE_ILLEGAL, instr, instr_pc); end
                            endcase
                            if (debug_state != ST_TRAP) debug_state <= ST_WB;
                        end

                        7'b0010011: begin
                            wb_en <= 1'b1;
                            case (funct3)
                                3'b000: wb_data <= rs1_val + imm_i;
                                3'b010: wb_data <= (s_rs1_val < $signed(imm_i)) ? 32'd1 : 32'd0;
                                3'b011: wb_data <= (rs1_val < imm_i) ? 32'd1 : 32'd0;
                                3'b100: wb_data <= rs1_val ^ imm_i;
                                3'b110: wb_data <= rs1_val | imm_i;
                                3'b111: wb_data <= rs1_val & imm_i;
                                3'b001: if (funct7 == 7'b0000000) wb_data <= rs1_val << instr[24:20]; else begin wb_en <= 1'b0; enter_trap(CAUSE_ILLEGAL, instr, instr_pc); end
                                3'b101: begin
                                    if (funct7 == 7'b0000000) wb_data <= rs1_val >> instr[24:20];
                                    else if (funct7 == 7'b0100000) wb_data <= $signed(rs1_val) >>> instr[24:20];
                                    else begin wb_en <= 1'b0; enter_trap(CAUSE_ILLEGAL, instr, instr_pc); end
                                end
                                default: begin wb_en <= 1'b0; enter_trap(CAUSE_ILLEGAL, instr, instr_pc); end
                            endcase
                            if (debug_state != ST_TRAP) debug_state <= ST_WB;
                        end

                        7'b0000011: begin
                            mem_addr <= rs1_val + imm_i;
                            mem_funct3 <= funct3;
                            mem_is_load <= 1'b1;
                            debug_state <= ST_MEM;
                        end

                        7'b0100011: begin
                            mem_addr <= rs1_val + imm_s;
                            mem_wdata <= rs2_val;
                            mem_funct3 <= funct3;
                            mem_is_load <= 1'b0;
                            debug_state <= ST_MEM;
                        end

                        7'b1100011: begin
                            case (funct3)
                                3'b000: commit_no_wb((rs1_val == rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                3'b001: commit_no_wb((rs1_val != rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                3'b100: commit_no_wb((s_rs1_val < s_rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                3'b101: commit_no_wb((s_rs1_val >= s_rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                3'b110: commit_no_wb((rs1_val < rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                3'b111: commit_no_wb((rs1_val >= rs2_val) ? instr_pc + imm_b : instr_pc + 32'd4);
                                default: enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                            endcase
                        end

                        7'b1101111: begin
                            if (((instr_pc + imm_j) & 32'h00000003) != 32'h00000000) begin
                                enter_trap(CAUSE_INSTR_FAULT, instr_pc + imm_j, instr_pc);
                            end else begin
                                wb_en <= 1'b1;
                                wb_data <= instr_pc + 32'd4;
                                next_pc <= instr_pc + imm_j;
                                debug_state <= ST_WB;
                            end
                        end

                        7'b1100111: begin
                            if (funct3 != 3'b000 || ((rs1_val + imm_i) & 32'h00000003) != 32'h00000000) begin
                                enter_trap(CAUSE_INSTR_FAULT, rs1_val + imm_i, instr_pc);
                            end else begin
                                wb_en <= 1'b1;
                                wb_data <= instr_pc + 32'd4;
                                next_pc <= (rs1_val + imm_i) & 32'hfffffffe;
                                debug_state <= ST_WB;
                            end
                        end

                        7'b0110111: begin
                            wb_en <= 1'b1;
                            wb_data <= imm_u;
                            debug_state <= ST_WB;
                        end

                        7'b0010111: begin
                            wb_en <= 1'b1;
                            wb_data <= instr_pc + imm_u;
                            debug_state <= ST_WB;
                        end

                        7'b1110011: begin
                            if (instr == 32'h00000073) begin
                                enter_trap((priv == PRIV_U) ? CAUSE_ECALL_U : CAUSE_ECALL_M, 32'h00000000, instr_pc);
                            end else if (instr == 32'h30200073) begin
                                if (priv != PRIV_M) begin
                                    enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                                end else begin
                                    priv <= mstatus[12:11];
                                    mstatus[3] <= mstatus[7];
                                    mstatus[7] <= 1'b1;
                                    mstatus[12:11] <= PRIV_U;
                                    commit_no_wb(mepc);
                                end
                            end else if (funct3 >= 3'b001 && funct3 <= 3'b111 && funct3 != 3'b100) begin
                                if (priv != PRIV_M && csr_addr[9:8] == 2'b11) begin
                                    enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                                end else begin
                                    wb_en <= (rd != 5'd0);
                                    wb_data <= csr_read(csr_addr);
                                    case (funct3)
                                        3'b001: csr_write(csr_addr, rs1_val);
                                        3'b010: if (rs1 != 5'd0) csr_write(csr_addr, csr_read(csr_addr) | rs1_val);
                                        3'b011: if (rs1 != 5'd0) csr_write(csr_addr, csr_read(csr_addr) & ~rs1_val);
                                        3'b101: csr_write(csr_addr, {27'h0000000, rs1});
                                        3'b110: if (rs1 != 5'd0) csr_write(csr_addr, csr_read(csr_addr) | {27'h0000000, rs1});
                                        3'b111: if (rs1 != 5'd0) csr_write(csr_addr, csr_read(csr_addr) & ~{27'h0000000, rs1});
                                        default: begin wb_en <= 1'b0; enter_trap(CAUSE_ILLEGAL, instr, instr_pc); end
                                    endcase
                                    if (debug_state != ST_TRAP) debug_state <= ST_WB;
                                end
                            end else begin
                                enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                            end
                        end

                        default: begin
                            enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                        end
                    endcase
                end

                ST_MEM: begin
                    debug_bus_valid <= 1'b1;
                    debug_bus_write <= !mem_is_load;
                    debug_bus_addr <= mem_addr;
                    if (mem_is_load) begin
                        if (mem_funct3 != 3'b000 && mem_funct3 != 3'b001 && mem_funct3 != 3'b010 && mem_funct3 != 3'b100 && mem_funct3 != 3'b101) begin
                            enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                        end else if (!pmp_allow(mem_addr, 1'b1, 1'b0, 1'b0)) begin
                            enter_trap(CAUSE_LOAD_FAULT, mem_addr, instr_pc);
                        end else begin
                            wb_en <= 1'b1;
                            wb_rd <= rd;
                            wb_data <= load_data(mem_addr, mem_funct3);
                            next_pc <= instr_pc + 32'd4;
                            debug_state <= ST_WB;
                        end
                    end else begin
                        if (mem_funct3 != 3'b000 && mem_funct3 != 3'b001 && mem_funct3 != 3'b010) begin
                            enter_trap(CAUSE_ILLEGAL, instr, instr_pc);
                        end else if (!pmp_allow(mem_addr, 1'b0, 1'b1, 1'b0)) begin
                            enter_trap(CAUSE_STORE_FAULT, mem_addr, instr_pc);
                        end else begin
                            case (mem_funct3)
                                3'b000: dmem[mem_addr] <= mem_wdata[7:0];
                                3'b001: begin
                                    dmem[mem_addr] <= mem_wdata[7:0];
                                    dmem[mem_addr + 1] <= mem_wdata[15:8];
                                end
                                3'b010: begin
                                    dmem[mem_addr] <= mem_wdata[7:0];
                                    dmem[mem_addr + 1] <= mem_wdata[15:8];
                                    dmem[mem_addr + 2] <= mem_wdata[23:16];
                                    dmem[mem_addr + 3] <= mem_wdata[31:24];
                                end
                            endcase
                            commit_no_wb(instr_pc + 32'd4);
                        end
                    end
                end

                ST_WB: begin
                    if (wb_en && wb_rd != 5'd0) begin
                        regs[wb_rd] <= wb_data;
                    end
                    pc <= next_pc;
                    minstret <= minstret + 32'd1;
                    debug_state <= ST_FETCH;
                end

                ST_TRAP: begin
                    mepc <= pending_mepc;
                    mcause <= pending_cause;
                    mtval <= pending_tval;
                    mstatus[12:11] <= priv;
                    mstatus[7] <= mstatus[3];
                    mstatus[3] <= 1'b0;
                    priv <= PRIV_M;
                    pc <= mtvec;
                    debug_state <= ST_FETCH;
                end

                default: begin
                    debug_state <= ST_FETCH;
                end
            endcase
        end
    end
endmodule
