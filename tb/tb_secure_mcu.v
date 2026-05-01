`timescale 1ns/1ps

module tb_secure_mcu;
    reg clk = 1'b0;
    reg rst = 1'b1;
    reg timer_irq = 1'b0;
    integer cycle = 0;
    integer halt_seen = 0;

    wire [31:0] pc;
    wire [31:0] instr;
    wire [2:0] debug_state;
    wire [1:0] debug_priv;
    wire [31:0] debug_trap_cause;
    wire debug_pmp_deny;
    wire debug_csr_write;
    wire debug_bus_valid;
    wire debug_bus_write;
    wire [31:0] debug_bus_addr;

    always #5 clk = ~clk;

    secure_riscv_mcu #(
        .IMEM_WORDS(256),
        .DMEM_BYTES(1024),
        .MEMFILE("programs/secure.hex")
    ) dut (
        .clk(clk),
        .rst(rst),
        .timer_irq(timer_irq),
        .software_irq(1'b0),
        .external_irq(1'b0),
        .pc(pc),
        .instr(instr),
        .debug_state(debug_state),
        .debug_priv(debug_priv),
        .debug_trap_cause(debug_trap_cause),
        .debug_pmp_deny(debug_pmp_deny),
        .debug_csr_write(debug_csr_write),
        .debug_bus_valid(debug_bus_valid),
        .debug_bus_write(debug_bus_write),
        .debug_bus_addr(debug_bus_addr)
    );

    initial begin
        $dumpfile("build/secure_cpu.vcd");
        $dumpvars(0, tb_secure_mcu);
        repeat (2) @(posedge clk);
        rst <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycle <= cycle + 1;
            timer_irq <= (cycle >= 34 && cycle <= 38);

            $display("cycle=%0d state=%0d priv=%0d pc=%08h instr=%08h cause=%08h pmp_deny=%0d csr=%0d bus=%0d wr=%0d addr=%08h pass=%0d irq=%0d user_data=%0d rom0=%0d x31=%0d",
                     cycle, debug_state, debug_priv, pc, instr, debug_trap_cause, debug_pmp_deny,
                     debug_csr_write, debug_bus_valid, debug_bus_write, debug_bus_addr,
                     {dut.dmem[771], dut.dmem[770], dut.dmem[769], dut.dmem[768]},
                     {dut.dmem[775], dut.dmem[774], dut.dmem[773], dut.dmem[772]},
                     {dut.dmem[515], dut.dmem[514], dut.dmem[513], dut.dmem[512]},
                     {dut.dmem[3], dut.dmem[2], dut.dmem[1], dut.dmem[0]},
                     dut.regs[31]);

            if (pc == 32'h000000a4) begin
                halt_seen <= halt_seen + 1;
            end else begin
                halt_seen <= 0;
            end

            if (halt_seen == 4) begin
                if ({dut.dmem[771], dut.dmem[770], dut.dmem[769], dut.dmem[768]} == 32'd1 &&
                    {dut.dmem[775], dut.dmem[774], dut.dmem[773], dut.dmem[772]} == 32'd1 &&
                    {dut.dmem[515], dut.dmem[514], dut.dmem[513], dut.dmem[512]} == 32'd7 &&
                    {dut.dmem[3], dut.dmem[2], dut.dmem[1], dut.dmem[0]} == 32'd0 &&
                    dut.mcause == 32'd8 &&
                    dut.priv == 2'd3 &&
                    dut.regs[31] == 32'd0) begin
                    $display("PASS: secure MCU interrupt, CSR, privilege, PMP, trap, and containment checks passed");
                end else begin
                    $display("FAIL: secure MCU final state mismatch");
                    $display("pass=%0d irq=%0d user_data=%0d rom0=%0d mcause=%08h priv=%0d x31=%0d pmpbase0=%08h",
                             {dut.dmem[771], dut.dmem[770], dut.dmem[769], dut.dmem[768]},
                             {dut.dmem[775], dut.dmem[774], dut.dmem[773], dut.dmem[772]},
                             {dut.dmem[515], dut.dmem[514], dut.dmem[513], dut.dmem[512]},
                             {dut.dmem[3], dut.dmem[2], dut.dmem[1], dut.dmem[0]},
                             dut.mcause, dut.priv, dut.regs[31], dut.pmp_base[0]);
                end
                $finish;
            end

            if (cycle > 300) begin
                $display("FAIL: secure MCU timeout");
                $finish;
            end
        end
    end
endmodule
