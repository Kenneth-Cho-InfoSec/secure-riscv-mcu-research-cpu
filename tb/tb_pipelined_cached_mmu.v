`timescale 1ns/1ps

module tb_pipelined_cached_mmu;
    reg clk = 1'b0;
    reg rst = 1'b1;
    integer cycle = 0;
    integer baseline_cycles = 0;

    wire [31:0] debug_pc;
    wire [31:0] debug_cycle;
    wire [31:0] debug_instret;
    wire [31:0] debug_icache_hits;
    wire [31:0] debug_icache_misses;
    wire [31:0] debug_dcache_hits;
    wire [31:0] debug_dcache_misses;
    wire [31:0] debug_mmu_hits;
    wire [31:0] debug_mmu_faults;
    wire debug_flush;
    wire debug_stall;
    wire halted;

    always #5 clk = ~clk;

    pipelined_cached_mmu_cpu #(
        .IMEM_WORDS(512),
        .DMEM_BYTES(2048),
        .MEMFILE("programs/perf.hex")
    ) dut (
        .clk(clk),
        .rst(rst),
        .debug_pc(debug_pc),
        .debug_cycle(debug_cycle),
        .debug_instret(debug_instret),
        .debug_icache_hits(debug_icache_hits),
        .debug_icache_misses(debug_icache_misses),
        .debug_dcache_hits(debug_dcache_hits),
        .debug_dcache_misses(debug_dcache_misses),
        .debug_mmu_hits(debug_mmu_hits),
        .debug_mmu_faults(debug_mmu_faults),
        .debug_flush(debug_flush),
        .debug_stall(debug_stall),
        .halted(halted)
    );

    initial begin
        $dumpfile("build/pipelined_cached_mmu.vcd");
        $dumpvars(0, tb_pipelined_cached_mmu);
        repeat (2) @(posedge clk);
        rst <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst) begin
            cycle <= cycle + 1;
            baseline_cycles = 100 * 4; // current secure multi-cycle style is roughly fetch/decode/execute/wb per ALU op.
            $display("cycle=%0d pc=%08h instret=%0d x5=%0d x6=%0d ic_hit=%0d ic_miss=%0d dc_hit=%0d dc_miss=%0d mmu_hit=%0d mmu_fault=%0d flush=%0d stall=%0d halted=%0d",
                     cycle, debug_pc, debug_instret, dut.regs[5], dut.regs[6],
                     debug_icache_hits, debug_icache_misses, debug_dcache_hits, debug_dcache_misses,
                     debug_mmu_hits, debug_mmu_faults, debug_flush, debug_stall, halted);

            if (halted) begin
                if (dut.regs[5] == 32'd96 &&
                    dut.regs[6] == 32'd96 &&
                    {dut.dmem[259], dut.dmem[258], dut.dmem[257], dut.dmem[256]} == 32'd96 &&
                    debug_mmu_faults == 32'd0 &&
                    debug_icache_hits > 32'd0 &&
                    debug_icache_misses > 32'd0 &&
                    debug_dcache_misses > 32'd0 &&
                    (baseline_cycles / debug_cycle) >= 3) begin
                    $display("PASS: pipelined cached MMU CPU completed benchmark with >=3x modeled speedup");
                    $display("PERF: baseline_cycles=%0d pipeline_cycles=%0d speedup_x100=%0d", baseline_cycles, debug_cycle, (baseline_cycles * 100) / debug_cycle);
                end else begin
                    $display("FAIL: pipelined cached MMU final/performance mismatch");
                    $display("x5=%0d x6=%0d mem256=%0d mmu_faults=%0d ic_h=%0d ic_m=%0d dc_h=%0d dc_m=%0d baseline=%0d cycles=%0d",
                             dut.regs[5], dut.regs[6],
                             {dut.dmem[259], dut.dmem[258], dut.dmem[257], dut.dmem[256]},
                             debug_mmu_faults, debug_icache_hits, debug_icache_misses,
                             debug_dcache_hits, debug_dcache_misses, baseline_cycles, debug_cycle);
                end
                $finish;
            end

            if (cycle > 180) begin
                $display("FAIL: pipelined cached MMU timeout");
                $finish;
            end
        end
    end
endmodule
